// swiftlint:disable no_sensitive_logging
import Dependencies
import Foundation
import FoundationModels
import StowerData

/// On-device AI client for article summarization and Q&A.
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
    public enum Availability: Equatable, Sendable {
        case available
        case appleIntelligenceNotEnabled
        case deviceNotEligible
        case modelNotReady
        case other(String)
    }

    /// Events emitted during a summarize call. `partial` carries the full
    /// snapshot so far (not a delta), per `LanguageModelSession.ResponseStream`
    /// semantics — views must replace, not append.
    public enum SummaryEvent: Sendable, Equatable {
        case started
        case stage(String)
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
    public var summarize: @Sendable (_ document: ReaderDocument?, _ plainText: String) -> AsyncThrowingStream<SummaryEvent, Error>
    public var ask: @Sendable (_ document: ReaderDocument?, _ plainText: String, _ question: String) -> AsyncThrowingStream<AnswerEvent, Error>
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

    public static let live: ArticleAIClient = {
        ArticleAIClient(
            availability: { liveAvailability() },
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
            }
        )
    }()

    public static let test = ArticleAIClient(
        availability: { .available },
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

    // MARK: - Token budgeting

    // Split of the context window: reserve room for instructions and
    // response, give the rest to the input.
    //
    // The reserves are deliberately generous (roughly 1/4 of a 4096 window).
    // The token estimator can undercount by ~25% on real articles, so the
    // extra headroom keeps even mis-estimated inputs from colliding with
    // the real context ceiling.
    //
    // Uses `SystemLanguageModel.contextSize` when available (iOS 26.4+),
    // otherwise falls back to the known 4 096-token window.
    private static func computeInputBudget() -> Int {
        let total: Int
        if #available(iOS 26.4, macOS 26.4, *) {
            total = SystemLanguageModel.default.contextSize
        } else {
            total = 4096
        }
        let instructionsReserve = 256
        let responseReserve = 768
        return max(512, total - instructionsReserve - responseReserve)
    }

    // MARK: - Summarize

    private static func performSummarize(
        document: ReaderDocument?,
        plainText: String,
        continuation: AsyncThrowingStream<SummaryEvent, Error>.Continuation
    ) async throws {
        guard !plainText.isEmpty else {
            continuation.yield(.finished(""))
            return
        }

        continuation.yield(.started)

        let budget = computeInputBudget()
        let approxInputTokens = ArticleChunker.approxTokenCount(plainText)

        // Single-session fast path — attempt, fall back to chunked on any
        // real-world context overflow. The estimator can still be wrong
        // even with the conservative char-per-token ratio, so this catch
        // is load-bearing for edge-case articles.
        if approxInputTokens <= budget {
            do {
                try Task.checkCancellation()
                try await streamSingleSessionSummary(
                    plainText: plainText,
                    continuation: continuation
                )
                return
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
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

        // swiftlint:disable:next prefer_let_over_var
        var sectionSummaries: [String] = []
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
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
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

        let budget = computeInputBudget()
        let articleTokens = ArticleChunker.approxTokenCount(plainText)
        let questionTokens = ArticleChunker.approxTokenCount(trimmedQuestion)

        // Stuff-context path — feed the whole article into instructions.
        if articleTokens + questionTokens <= budget {
            do {
                try Task.checkCancellation()
                try await streamStuffedAnswer(
                    plainText: plainText,
                    question: trimmedQuestion,
                    continuation: continuation
                )
                return
            } catch let error as LanguageModelSession.GenerationError {
                // Budget estimator was off; fall through to retrieval.
                if case .exceededContextWindowSize = error {
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

        let retrievalChunkBudget = 300
        let retrievalTopK = 8
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
        let prompt = """
            Here is the full article:

            \(plainText)

            ---

            Based on the article above, answer this question: \(question)
            """

        var lastContent = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            lastContent = snapshot.content
            continuation.yield(.partial(lastContent))
        }
        continuation.yield(.finished(lastContent))
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
// swiftlint:enable no_sensitive_logging
