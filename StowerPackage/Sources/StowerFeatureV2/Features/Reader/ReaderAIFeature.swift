import ComposableArchitecture
import Foundation
import StowerData

/// Child feature of the reader that owns the AI popover's state and effects.
///
/// Composed under `ReaderFeature` alongside `ReaderSpeechFeature`. Mirrors the
/// speech feature's shape: state for both modes lives in a single reducer,
/// events flow from an `AsyncThrowingStream`-based client, and cancellation
/// is keyed by `CancelID` so closing the popover atomically tears down any
/// in-flight work.
///
/// The reducer doesn't own the article text — `ReaderFeature` owns that, and
/// passes it in via the `summarizeRequested` / `askSubmitted` actions. This
/// keeps `ReaderAIFeature.State` lean and avoids stale snapshots when the
/// user switches render modes or reloads the article.
@Reducer
public struct ReaderAIFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var itemID: UUID?
        public var availability: ArticleAIClient.Availability = .available
        public var enhancedAvailability: ArticleAIClient.Availability = .available
        public var mode: Mode = .summary

        // MARK: Summary tab
        public var summaryQuality: ArticleAIClient.SummaryQuality = .quick
        public var summaryResultQuality: ArticleAIClient.SummaryQuality = .quick
        public var summaryText: String = ""
        public var summaryStage: String?
        public var summaryWasCached = false
        public var summaryGeneratedAt: Date?
        public var isSummarizing = false
        public var summaryError: String?

        // MARK: Ask tab
        public var question: String = ""
        public var pendingAnswer: String = ""
        public var transcript = [QAEntry]()
        public var isAnswering = false
        public var isRetrieving = false
        public var askError: String?

        public enum Mode: String, Equatable, Sendable {
            case summary = "summary"
            case ask = "ask"
        }

        public struct QAEntry: Equatable, Identifiable, Sendable {
            public let id: UUID
            public let question: String
            public let answer: String

            public init(question: String, answer: String, id: UUID = UUID()) {
                self.id = id
                self.question = question
                self.answer = answer
            }
        }

        public init() {}
    }

    public enum Action: Equatable {
        /// Parent forwards this after the reader finishes loading so we can
        /// warm the availability check and the cached-summary lookup.
        case appeared(itemID: UUID)
        case cacheLoaded(
            quality: ArticleAIClient.SummaryQuality,
            text: String?,
            generatedAt: Date?
        )
        case panelOpened
        case modeChanged(State.Mode)

        // Summary
        case summaryQualityChanged(ArticleAIClient.SummaryQuality)
        case summarizeRequested(document: ReaderDocument?, plainText: String)
        case summaryEvent(ArticleAIClient.SummaryEvent)
        case summaryFailed(String)

        // Ask
        case questionChanged(String)
        case askSubmitted(document: ReaderDocument?, plainText: String)
        case answerEvent(ArticleAIClient.AnswerEvent)
        case answerFailed(String)
        case clearTranscript

        /// Sent on popover dismiss to tear down any in-flight AI work.
        case cancelAll
    }

    private enum CancelID {
        case summarize
        case ask
    }

    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.articleAIClient)
    var ai

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared(let itemID):
                state.itemID = itemID
                state.availability = ai.availability()
                state.enhancedAvailability = ai.enhancedAvailability()
                return loadCachedSummary(itemID: itemID, quality: state.summaryQuality)

            case let .cacheLoaded(quality, text, generatedAt):
                guard quality == state.summaryQuality else { return .none }
                if let text, !text.isEmpty {
                    state.summaryText = text
                    state.summaryGeneratedAt = generatedAt
                    state.summaryWasCached = true
                    state.summaryResultQuality = quality
                }
                return .none

            case .panelOpened:
                state.availability = ai.availability()
                state.enhancedAvailability = ai.enhancedAvailability()
                switch state.summaryQuality {
                case .quick:
                    ai.prewarm()
                case .enhanced:
                    ai.prewarmEnhanced()
                }
                return .none

            case .modeChanged(let mode):
                state.mode = mode
                return .none

            case .summaryQualityChanged(let quality):
                guard quality != state.summaryQuality else { return .none }
                state.summaryQuality = quality
                state.summaryResultQuality = quality
                state.summaryText = ""
                state.summaryStage = nil
                state.summaryError = nil
                state.summaryWasCached = false
                state.summaryGeneratedAt = nil
                state.isSummarizing = false

                switch quality {
                case .quick:
                    ai.prewarm()
                case .enhanced:
                    state.enhancedAvailability = ai.enhancedAvailability()
                    ai.prewarmEnhanced()
                }

                guard let itemID = state.itemID else {
                    return .cancel(id: CancelID.summarize)
                }
                return .merge(
                    .cancel(id: CancelID.summarize),
                    loadCachedSummary(itemID: itemID, quality: quality)
                )

            case let .summarizeRequested(document, plainText):
                switch state.summaryQuality {
                case .quick:
                    guard state.availability == .available else { return .none }
                case .enhanced:
                    // An unavailable PCC model can still fall back to Quick,
                    // but only if the on-device model is available.
                    guard state.enhancedAvailability == .available
                        || state.availability == .available
                    else {
                        return .none
                    }
                }
                guard !state.isSummarizing else { return .none }
                guard !plainText.isEmpty else {
                    state.summaryError = "This article doesn't have any text to summarize."
                    return .none
                }

                state.isSummarizing = true
                state.summaryText = ""
                state.summaryStage = nil
                state.summaryError = nil
                state.summaryWasCached = false
                state.summaryGeneratedAt = nil
                state.summaryResultQuality = state.summaryQuality

                let ai = self.ai
                let quality = state.summaryQuality
                return .run { send in
                    do {
                        let events = switch quality {
                        case .quick:
                            ai.summarize(document, plainText)
                        case .enhanced:
                            ai.summarizeEnhanced(document, plainText)
                        }
                        for try await event in events {
                            await send(.summaryEvent(event))
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.summaryFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.summarize, cancelInFlight: true)

            case .summaryEvent(let event):
                switch event {
                case .started:
                    return .none

                case .stage(let label):
                    state.summaryStage = label
                    return .none

                case .qualityResolved(let quality):
                    state.summaryResultQuality = quality
                    return .none

                case .partial(let snapshot):
                    // ResponseStream yields full snapshots, not deltas — replace.
                    state.summaryText = snapshot
                    state.summaryStage = nil
                    return .none

                case .finished(let final):
                    state.summaryText = final
                    state.summaryStage = nil
                    state.isSummarizing = false
                    state.summaryGeneratedAt = Date.now
                    state.summaryWasCached = false

                    // Persist to the local cache table. Fire-and-forget: UI
                    // already shows the summary, a DB failure shouldn't
                    // affect the user's current reading session.
                    guard let itemID = state.itemID, !final.isEmpty else {
                        return .cancel(id: CancelID.summarize)
                    }
                    let repository = self.repository
                    let quality = state.summaryResultQuality
                    let promptVersion = ai.summaryPromptVersion(quality)
                    return .merge(
                        .cancel(id: CancelID.summarize),
                        .run { _ in
                            try? await repository.saveSummary(
                                itemID,
                                quality.rawValue,
                                promptVersion,
                                final
                            )
                        }
                    )
                }

            case .summaryFailed(let message):
                state.isSummarizing = false
                state.summaryError = message
                state.summaryStage = nil
                return .cancel(id: CancelID.summarize)

            case .questionChanged(let text):
                state.question = text
                return .none

            case let .askSubmitted(document, plainText):
                guard state.availability == .available else { return .none }
                let trimmed = state.question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }
                guard !state.isAnswering else { return .none }
                guard !plainText.isEmpty else {
                    state.askError = "This article doesn't have any text to search."
                    return .none
                }

                state.isAnswering = true
                state.pendingAnswer = ""
                state.askError = nil
                state.isRetrieving = false

                let ai = self.ai
                return .run { send in
                    do {
                        for try await event in ai.ask(document, plainText, trimmed) {
                            await send(.answerEvent(event))
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.answerFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.ask, cancelInFlight: true)

            case .answerEvent(let event):
                switch event {
                case .started:
                    return .none

                case .retrievingContext:
                    state.isRetrieving = true
                    return .none

                case .partial(let snapshot):
                    state.pendingAnswer = snapshot
                    state.isRetrieving = false
                    return .none

                case .finished(let final):
                    let askedQuestion = state.question.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !final.isEmpty {
                        state.transcript.append(
                            State.QAEntry(question: askedQuestion, answer: final)
                        )
                    }
                    state.pendingAnswer = ""
                    state.question = ""
                    state.isAnswering = false
                    state.isRetrieving = false
                    return .cancel(id: CancelID.ask)
                }

            case .answerFailed(let message):
                state.isAnswering = false
                state.isRetrieving = false
                state.askError = message
                return .cancel(id: CancelID.ask)

            case .clearTranscript:
                state.transcript.removeAll()
                state.pendingAnswer = ""
                state.askError = nil
                return .none

            case .cancelAll:
                state.isSummarizing = false
                state.isAnswering = false
                state.isRetrieving = false
                state.summaryStage = nil
                return .merge(
                    .cancel(id: CancelID.summarize),
                    .cancel(id: CancelID.ask)
                )
            }
        }
    }

    private func loadCachedSummary(
        itemID: UUID,
        quality: ArticleAIClient.SummaryQuality
    ) -> EffectOf<Self> {
        let repository = self.repository
        let promptVersion = ai.summaryPromptVersion(quality)
        return .run { send in
            let cached = try? await repository.loadSummary(
                itemID,
                quality.rawValue,
                promptVersion
            )
            await send(
                .cacheLoaded(
                    quality: quality,
                    text: cached?.text,
                    generatedAt: cached?.generatedAt
                )
            )
        }
    }
}
