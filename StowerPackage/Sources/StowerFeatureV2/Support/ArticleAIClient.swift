import Dependencies
import Foundation
import FoundationModels
import StowerData

/// AI client for article summarization and on-device Q&A.
///
/// Wraps Apple's Foundation Models framework (`SystemLanguageModel` +
/// `LanguageModelSession`) in an `AsyncThrowingStream` event surface that
/// mirrors `ReaderSpeechClient`. The feature layer stays free of
/// `FoundationModels` imports so test targets can substitute a fake without
/// requiring iOS 26 availability in unit tests.
///
/// Strategy:
///   - **Summarize**: single-session path when the article fits in the context
///     window; hierarchical map-reduce over chunked sections when it doesn't.
///     Only the final reduce step streams to the UI — map steps are silent.
///   - **Ask**: stuff-context when the article fits; NLEmbedding retrieval
///     over chunked sections when it doesn't.
public struct ArticleAIClient: Sendable {
    public enum SummaryQuality: String, CaseIterable, Equatable, Sendable {
        case quick = "quick"
        case enhanced = "enhanced"
    }

    public enum Availability: Equatable, Sendable {
        case available
        case appleIntelligenceNotEnabled
        case deviceNotEligible
        case modelNotReady
        case quotaLimitReached(Date?)
        case other(String)
    }

    /// Events emitted during a summarize call. `partial` carries the full
    /// snapshot so far (not a delta), per `LanguageModelSession.ResponseStream`
    /// semantics — views must replace, not append.
    public enum SummaryEvent: Sendable, Equatable {
        case started
        case stage(String)
        /// Emitted when Enhanced generation has to continue on device. This
        /// keeps the result out of the Enhanced cache.
        case qualityResolved(SummaryQuality)
        case partial(String)
        case finished(String)
    }

    public enum AnswerEvent: Sendable, Equatable {
        case started
        case retrievingContext
        case partial(String)
        case finished(String)
    }

    public var availability: @Sendable () -> Availability
    public var prewarm: @Sendable () -> Void
    public var summarize: @Sendable (_ document: ReaderDocument?, _ plainText: String) -> AsyncThrowingStream<SummaryEvent, Error>
    public var ask: @Sendable (_ document: ReaderDocument?, _ plainText: String, _ question: String) -> AsyncThrowingStream<AnswerEvent, Error>
    public var enhancedAvailability: @Sendable () -> Availability = {
        .other("Enhanced summaries aren't configured.")
    }
    public var prewarmEnhanced: @Sendable () -> Void = {}
    public var summarizeEnhanced: @Sendable (
        _ document: ReaderDocument?,
        _ plainText: String
    ) -> AsyncThrowingStream<SummaryEvent, Error> = { _, _ in
        AsyncThrowingStream { $0.finish() }
    }
    public var summaryPromptVersion: @Sendable (SummaryQuality) -> Int = { _ in 1 }
}

// MARK: - Dependency Registration

private enum ArticleAIClientKey: DependencyKey {
    static let liveValue: ArticleAIClient = .live
    static let testValue: ArticleAIClient = .test
}

extension DependencyValues {
    public var articleAIClient: ArticleAIClient {
        get { self[ArticleAIClientKey.self] }
        set { self[ArticleAIClientKey.self] = newValue }
    }
}

// MARK: - Live Implementation

extension ArticleAIClient {
    /// Keep PCC dormant until the managed entitlement is approved. This gate
    /// prevents availability checks, prewarming, and generation from touching
    /// the private-cloud model while preserving the implementation for later.
    private static let privateCloudComputeEnabled = false

    /// Instructions tuning notes:
    ///   - Short, imperative, one task per prompt (per Apple's guidance in
    ///     TN3193 — long instructions consume tokens and degrade quality).
    ///   - Explicitly bound response length so the model doesn't run away
    ///     with multi-paragraph output.
    private enum Instructions {
        static let singleShotSummary = """
            You summarize articles for a read-later app. Produce a concise \
            4 to 6 sentence summary capturing the main points. Use clear, \
            direct language. Do not add information that isn't in the article.
            """

        static let sectionSummary = """
            Summarize the following article text in 2 to 3 sentences, \
            capturing its key points. Use clear, direct language. Do not \
            add information that isn't in the text. Write plainly — do \
            not start with "This section", "The text", or similar framing.
            """

        static let reduceSummary = """
            You summarize articles for a read-later app. The user's \
            message contains notes taken while reading a longer article. \
            Produce a cohesive 4 to 6 sentence summary of the full \
            article based on those notes. Use clear, direct language. \
            Write as if you've just read the article yourself — never \
            mention "sections", "parts", "notes", or "summaries" in your \
            response. Do not add information that isn't in the notes.
            """

        static let enhancedSummary = """
            Summarize the supplied article for an attentive reader. Identify \
            its central claim, the strongest supporting points, why the piece \
            matters, and important qualifications or disagreement in the \
            source. Preserve nuance and distinguish the author's claims from \
            established facts. Never invent details or use outside knowledge.
            """

        static let enhancedSectionSummary = """
            Extract dense, faithful notes from this portion of a long article. \
            Preserve claims, evidence, names, numbers, and qualifications that \
            may be important to understanding the full piece. Do not add \
            outside information.
            """

        static let stuffedAnswer = """
            You help a reader understand an article they've saved. The \
            user's message contains the article followed by a question. \
            Answer the question in 2 to 5 sentences, grounded in what the \
            article actually says. Quote or paraphrase the article's own \
            wording where it's on-point, and explain the reasoning — don't \
            stop at a one-word yes or no. Only say you can't find something \
            if the article genuinely doesn't discuss it.
            """

        static let retrievalAnswer = """
            You help a reader understand an article they've saved. The \
            user's message contains relevant passages from the article \
            followed by a question. Answer the question in 2 to 5 \
            sentences, grounded in what the passages say. Quote or \
            paraphrase the passages where they're on-point, and explain \
            the reasoning — don't stop at a one-word yes or no. Speak as \
            if you're referring to the article itself: never mention \
            "passages", "excerpts", "sections", or numbered labels to the \
            reader. Only say you can't find something if the passages \
            genuinely don't discuss it.
            """
    }

    /// Shared `SystemLanguageModel` instance configured with permissive
    /// content-transformation guardrails. Read-later content frequently
    /// trips the default guardrails as false positives — security course
    /// material, benefits summaries, medical articles, historical texts,
    /// legal documents, etc. all contain words that Apple's default
    /// guardrail flags as "unsafe," producing `guardrailViolation` errors
    /// on perfectly innocent inputs. `permissiveContentTransformations`
    /// (iOS 26+) is the designated opt-out: the framework still filters
    /// outright harmful generation, but allows text transformation
    /// (summarization, Q&A) over content that isn't itself being asked
    /// to cause harm. That's exactly the transformation surface this
    /// client operates on.
    private static let permissiveModel: SystemLanguageModel = {
        SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }()

    private static let prewarmSession = LanguageModelSession(
        model: permissiveModel,
        instructions: Instructions.singleShotSummary
    )

    private static let privateCloudModel = PrivateCloudComputeLanguageModel()

    private static let enhancedPrewarmSession = LanguageModelSession(
        model: privateCloudModel,
        instructions: Instructions.enhancedSummary
    )

    @Generable(description: "A faithful, useful summary of a saved article")
    struct EnhancedArticleSummary {
        @Guide(description: "A concise overview of the article's central argument in two or three sentences")
        var overview: String

        @Guide(description: "Three to six specific supporting ideas, findings, or arguments from the article")
        var keyPoints: [String]

        @Guide(description: "Why the article or its argument matters to the reader")
        var significance: String

        @Guide(description: "Important caveats, uncertainty, counterarguments, or limitations stated in the article")
        var qualifications: [String]
    }

    public static let live: ArticleAIClient = {
        ArticleAIClient(
            availability: { liveAvailability() },
            prewarm: { prewarmSession.prewarm() },
            summarize: { document, plainText in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try await performSummarize(
                                document: document,
                                plainText: plainText,
                                continuation: continuation
                            )
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            ask: { document, plainText, question in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try await performAsk(
                                document: document,
                                plainText: plainText,
                                question: question,
                                continuation: continuation
                            )
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            enhancedAvailability: {
                guard privateCloudComputeEnabled else {
                    return .other("Enhanced summaries are currently disabled.")
                }
                return liveEnhancedAvailability()
            },
            prewarmEnhanced: {
                guard privateCloudComputeEnabled else { return }
                enhancedPrewarmSession.prewarm()
            },
            summarizeEnhanced: { document, plainText in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try await performEnhancedSummarize(
                                document: document,
                                plainText: plainText,
                                continuation: continuation
                            )
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            summaryPromptVersion: { quality in
                switch quality {
                case .quick:
                    2
                case .enhanced:
                    1
                }
            }
        )
    }()

    public static let test = ArticleAIClient(
        availability: { .available },
        prewarm: {},
        summarize: { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.started)
                continuation.yield(.partial("Test summary."))
                continuation.yield(.finished("Test summary."))
                continuation.finish()
            }
        },
        ask: { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.started)
                continuation.yield(.partial("Test answer."))
                continuation.yield(.finished("Test answer."))
                continuation.finish()
            }
        }
    )

    // MARK: - Availability

    private static func liveAvailability() -> Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .other("Apple Intelligence is unavailable.")
            }
        }
    }

    private static func liveEnhancedAvailability() -> Availability {
        switch privateCloudModel.availability {
        case .available:
            let usage = privateCloudModel.quotaUsage
            return usage.isLimitReached ? .quotaLimitReached(usage.resetDate) : .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .systemNotReady:
                return .modelNotReady
            @unknown default:
                return .other("Private Cloud Compute is unavailable.")
            }
        }
    }

    // MARK: - Token budgeting

    private static func computeInputBudget(instructions: String) async throws -> Int {
        let contextSize = permissiveModel.contextSize
        let instructionTokens = try await permissiveModel.tokenCount(
            for: FoundationModels.Instructions(instructions)
        )
        let responseReserve = 768
        return max(512, contextSize - instructionTokens - responseReserve)
    }

    private static func promptFits(
        _ prompt: String,
        instructions: String
    ) async throws -> Bool {
        let budget = try await computeInputBudget(instructions: instructions)
        let promptTokens = try await permissiveModel.tokenCount(
            for: Prompt(prompt)
        )
        return promptTokens <= budget
    }

    // MARK: - Summarize

    private static func performEnhancedSummarize(
        document: ReaderDocument?,
        plainText: String,
        continuation: AsyncThrowingStream<SummaryEvent, Error>.Continuation
    ) async throws {
        guard !plainText.isEmpty else {
            continuation.yield(.finished(""))
            return
        }

        continuation.yield(.started)

        guard privateCloudComputeEnabled else {
            try await fallBackToQuickSummary(
                reason: "Generating summary on device",
                document: document,
                plainText: plainText,
                continuation: continuation
            )
            return
        }

        guard liveEnhancedAvailability() == .available else {
            try await fallBackToQuickSummary(
                reason: "Enhanced summary unavailable — continuing on device",
                document: document,
                plainText: plainText,
                continuation: continuation
            )
            return
        }

        continuation.yield(.stage("Reasoning across the full article"))
        do {
            let result = try await generateEnhancedSummary(from: plainText)
            continuation.yield(.partial(result))
            continuation.yield(.finished(result))
        } catch let error as LanguageModelError {
            if case .contextSizeExceeded = error {
                do {
                    try await performChunkedEnhancedSummarize(
                        document: document,
                        plainText: plainText,
                        continuation: continuation
                    )
                } catch is PrivateCloudComputeLanguageModel.Error {
                    try await fallBackToQuickSummary(
                        reason: "Private Cloud Compute couldn't finish — continuing on device",
                        document: document,
                        plainText: plainText,
                        continuation: continuation
                    )
                }
            } else {
                throw error
            }
        } catch is PrivateCloudComputeLanguageModel.Error {
            try await fallBackToQuickSummary(
                reason: "Private Cloud Compute couldn't finish — continuing on device",
                document: document,
                plainText: plainText,
                continuation: continuation
            )
        }
    }

    private static func generateEnhancedSummary(from articleText: String) async throws -> String {
        let session = LanguageModelSession(
            model: privateCloudModel,
            instructions: Instructions.enhancedSummary
        )
        let response = try await session.respond(
            to: "Article:\n\n\(articleText)",
            generating: EnhancedArticleSummary.self,
            options: GenerationOptions(maximumResponseTokens: 1400),
            contextOptions: ContextOptions(reasoningLevel: .moderate)
        )
        return render(response.content)
    }

    private static func performChunkedEnhancedSummarize(
        document: ReaderDocument?,
        plainText: String,
        continuation: AsyncThrowingStream<SummaryEvent, Error>.Continuation
    ) async throws {
        // PCC exposes its context size, but not its tokenizer. This conservative
        // chunk budget leaves room for instructions and reasoning output; an
        // overflow at the final pass still surfaces as a normal model error.
        let chunks = ArticleChunker.chunks(
            from: document,
            plainText: plainText,
            budgetTokens: 20_000
        )
        guard !chunks.isEmpty else {
            continuation.yield(.finished(""))
            return
        }

        var notes = [String]()
        notes.reserveCapacity(chunks.count)
        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            continuation.yield(.stage("Reading part \(offset + 1) of \(chunks.count)"))
            let session = LanguageModelSession(
                model: privateCloudModel,
                instructions: Instructions.enhancedSectionSummary
            )
            let response = try await session.respond(
                to: chunk.text,
                options: GenerationOptions(maximumResponseTokens: 900),
                contextOptions: ContextOptions(reasoningLevel: .light)
            )
            notes.append(response.content)
        }

        try Task.checkCancellation()
        continuation.yield(.stage("Connecting the article's ideas"))
        let result = try await generateEnhancedSummary(from: notes.joined(separator: "\n\n"))
        continuation.yield(.partial(result))
        continuation.yield(.finished(result))
    }

    private static func fallBackToQuickSummary(
        reason: String,
        document: ReaderDocument?,
        plainText: String,
        continuation: AsyncThrowingStream<SummaryEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.qualityResolved(.quick))
        continuation.yield(.stage(reason))
        try await performQuickSummarize(
            document: document,
            plainText: plainText,
            continuation: continuation,
            emitStarted: false
        )
    }

    private static func render(_ summary: EnhancedArticleSummary) -> String {
        var sections = [summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)]
        let keyPoints = summary.keyPoints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !keyPoints.isEmpty {
            sections.append("Key points\n" + keyPoints.map { "• \($0)" }.joined(separator: "\n"))
        }
        let significance = summary.significance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !significance.isEmpty {
            sections.append("Why it matters\n\(significance)")
        }
        let qualifications = summary.qualifications
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !qualifications.isEmpty {
            sections.append("Qualifications\n" + qualifications.map { "• \($0)" }.joined(separator: "\n"))
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func performSummarize(
        document: ReaderDocument?,
        plainText: String,
        continuation: AsyncThrowingStream<SummaryEvent, Error>.Continuation
    ) async throws {
        try await performQuickSummarize(
            document: document,
            plainText: plainText,
            continuation: continuation,
            emitStarted: true
        )
    }

    private static func performQuickSummarize(
        document: ReaderDocument?,
        plainText: String,
        continuation: AsyncThrowingStream<SummaryEvent, Error>.Continuation,
        emitStarted: Bool
    ) async throws {
        guard !plainText.isEmpty else {
            continuation.yield(.finished(""))
            return
        }

        if emitStarted {
            continuation.yield(.started)
        }

        let budget = try await computeInputBudget(instructions: Instructions.sectionSummary)
        let singleShotPrompt = "Summarize this article:\n\n\(plainText)"

        // Single-session fast path — attempt, fall back to chunked on any
        // real-world context overflow. The estimator can still be wrong
        // even with the conservative char-per-unit ratio, so this catch
        // is load-bearing for edge-case articles.
        if try await promptFits(singleShotPrompt, instructions: Instructions.singleShotSummary) {
            do {
                try Task.checkCancellation()
                try await streamSingleSessionSummary(
                    plainText: plainText,
                    continuation: continuation
                )
                return
            } catch let error as LanguageModelError {
                if case .contextSizeExceeded = error {
                    // Reset any partial snapshot that streamed before the
                    // failure and announce the retry, then fall through.
                    continuation.yield(.partial(""))
                    continuation.yield(.stage("Article was longer than expected — chunking"))
                } else {
                    throw error
                }
            }
        }

        // Chunked map-reduce path.
        let chunks = ArticleChunker.chunks(
            from: document,
            plainText: plainText,
            budgetTokens: budget
        )

        guard !chunks.isEmpty else {
            // No chunks to map over and the single-session path already
            // failed (or wasn't attempted). Nothing more we can do — yield
            // an empty finished event so the UI returns to idle rather
            // than hanging with `isSummarizing = true`.
            continuation.yield(.finished(""))
            return
        }

        var sectionSummaries = [String]()
        sectionSummaries.reserveCapacity(chunks.count)

        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // Stage labels are user-facing progress UI, not model input —
            // the model never sees these strings, so they can mention
            // "section" without leaking into the final summary.
            continuation.yield(.stage("Summarizing section \(offset + 1) of \(chunks.count)"))

            let sectionSession = LanguageModelSession(
                model: permissiveModel,
                instructions: Instructions.sectionSummary
            )
            // Raw chunk text only — no "Section 1 of 2:" preamble, which
            // would otherwise bleed into the section summary output and
            // then into the final reduce pass.
            let response = try await sectionSession.respond(to: chunk.text)
            sectionSummaries.append(response.content)
        }

        try Task.checkCancellation()
        continuation.yield(.stage("Combining sections"))

        // Combined input for the reduce step. No "Section N:" labels — we
        // feed the collected notes in as plain paragraphs so the model
        // doesn't echo a section structure back to the user.
        let combinedInput = sectionSummaries.joined(separator: "\n\n")

        // Concatenated section summaries as a last-resort fallback if the
        // reduce step can't complete. Not as polished as a reduced
        // summary but still coherent prose — and crucially no "Section 1
        // of 2" framing because we stopped emitting that above.
        let concatenatedFallback = combinedInput

        let reduceSession = LanguageModelSession(
            model: permissiveModel,
            instructions: Instructions.reduceSummary
        )
        let reducePrompt = combinedInput

        do {
            var lastContent = ""
            for try await snapshot in reduceSession.streamResponse(to: reducePrompt) {
                try Task.checkCancellation()
                lastContent = snapshot.content
                continuation.yield(.partial(lastContent))
            }
            continuation.yield(.finished(lastContent))
        } catch let error as LanguageModelError {
            if case .contextSizeExceeded = error {
                // Combined section summaries are themselves too big for a
                // single session. Emit the concatenation as the final
                // result so the user still gets something useful.
                continuation.yield(.partial(concatenatedFallback))
                continuation.yield(.finished(concatenatedFallback))
            } else {
                throw error
            }
        }
    }

    private static func streamSingleSessionSummary(
        plainText: String,
        continuation: AsyncThrowingStream<SummaryEvent, Error>.Continuation
    ) async throws {
        let session = LanguageModelSession(
            model: permissiveModel,
            instructions: Instructions.singleShotSummary
        )
        let prompt = "Summarize this article:\n\n\(plainText)"

        var lastContent = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            lastContent = snapshot.content
            continuation.yield(.partial(lastContent))
        }
        continuation.yield(.finished(lastContent))
    }

    // MARK: - Ask

    private static func performAsk(
        document: ReaderDocument?,
        plainText: String,
        question: String,
        continuation: AsyncThrowingStream<AnswerEvent, Error>.Continuation
    ) async throws {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            continuation.yield(.finished(""))
            return
        }

        continuation.yield(.started)

        let stuffedPrompt = stuffedAnswerPrompt(
            plainText: plainText,
            question: trimmedQuestion
        )

        // Stuff-context path — feed the whole article into instructions.
        if try await promptFits(stuffedPrompt, instructions: Instructions.stuffedAnswer) {
            do {
                try Task.checkCancellation()
                try await streamStuffedAnswer(
                    plainText: plainText,
                    question: trimmedQuestion,
                    continuation: continuation
                )
                return
            } catch let error as LanguageModelError {
                // Budget estimator was off; fall through to retrieval.
                if case .contextSizeExceeded = error {
                    // fall through
                } else {
                    throw error
                }
            }
        }

        // Retrieval fallback.
        //
        // Critical: retrieval needs *small* chunks. The summary path's
        // budget (~3072) is sized so ONE chunk fits per session, but
        // retrieval combines top-k chunks into a single session alongside
        // instructions and the question. Re-chunk here with a per-chunk
        // budget small enough that k * chunkBudget fits comfortably inside
        // the real context window.
        continuation.yield(.retrievingContext)

        let retrievalTopK = 8
        let retrievalInputBudget = try await computeInputBudget(
            instructions: Instructions.retrievalAnswer
        )
        let questionTokens = try await permissiveModel.tokenCount(for: Prompt(trimmedQuestion))
        let retrievalChunkBudget = max(
            128,
            (retrievalInputBudget - questionTokens - 128) / retrievalTopK
        )
        let retrievalChunks = ArticleChunker.chunks(
            from: document,
            plainText: plainText,
            budgetTokens: retrievalChunkBudget
        )
        let relevant = ArticleRetriever.topChunks(
            question: trimmedQuestion,
            chunks: retrievalChunks,
            k: retrievalTopK
        )

        // Plain separator between passages — no numbered "Excerpt N" labels
        // that the model would otherwise cite back to the user. The
        // instructions already tell the model to speak as if referring to
        // the article itself.
        let excerptText = relevant
            .map { $0.text }
            .joined(separator: "\n\n- - -\n\n")

        try Task.checkCancellation()
        try await streamRetrievalAnswer(
            excerpts: excerptText,
            question: trimmedQuestion,
            continuation: continuation
        )
    }

    private static func streamStuffedAnswer(
        plainText: String,
        question: String,
        continuation: AsyncThrowingStream<AnswerEvent, Error>.Continuation
    ) async throws {
        let session = LanguageModelSession(
            model: permissiveModel,
            instructions: Instructions.stuffedAnswer
        )
        let prompt = stuffedAnswerPrompt(plainText: plainText, question: question)

        var lastContent = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            lastContent = snapshot.content
            continuation.yield(.partial(lastContent))
        }
        continuation.yield(.finished(lastContent))
    }

    private static func stuffedAnswerPrompt(
        plainText: String,
        question: String
    ) -> String {
        """
            Here is the full article:

            \(plainText)

            ---

            Based on the article above, answer this question: \(question)
            """
    }

    private static func streamRetrievalAnswer(
        excerpts: String,
        question: String,
        continuation: AsyncThrowingStream<AnswerEvent, Error>.Continuation
    ) async throws {
        let session = LanguageModelSession(
            model: permissiveModel,
            instructions: Instructions.retrievalAnswer
        )
        let prompt = """
            Relevant passages from the article:

            \(excerpts)

            ---

            Based on the article, answer this question: \(question)
            """

        var lastContent = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            lastContent = snapshot.content
            continuation.yield(.partial(lastContent))
        }
        continuation.yield(.finished(lastContent))
    }
}
