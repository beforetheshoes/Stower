import ComposableArchitecture
import Foundation

@Reducer
public struct ReaderSpeechFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        var isSpeaking = false
        var isPaused = false
        var selectedVoiceID: String?
        // Stored as a multiplier on AVSpeechUtteranceDefaultSpeechRate.
        var rate: Float = 1.0

        var currentBlockIndex: Int?
        var currentRangeInBlockUTF16: NSRange?

        /// Monotonic sequence number of the speech unit currently being
        /// spoken. Set from `didStart` / `willSpeak` events. Distinct
        /// from `currentBlockIndex` because a single document block can
        /// be broken into many sentence-level speech units that all
        /// share the same block index but have different sequence
        /// numbers — the skip buttons iterate sequences so you can
        /// advance one sentence at a time inside a long paragraph.
        var currentSequence: Int?

        /// The speech units currently queued for playback, captured
        /// from the most recent `listenTapped`. Used to restart
        /// playback in-place when the rate or voice changes mid-session
        /// and to compute skip forward/backward targets. Sentence-split
        /// by the caller — one `SpeechBlock` per sentence in the
        /// typical case, so filter operations use `sequence` for
        /// identity rather than `index` (which is non-unique across
        /// sentences of the same block).
        var currentBlocks = [SpeechBlock]()

        var errorMessage: String?
    }

    public enum Action: Equatable {
        case loadPreferences
        case preferencesLoaded(ReaderSpeechPreferences)

        case listenTapped(blocks: [SpeechBlock])
        case pauseTapped
        case resumeTapped
        case stopTapped
        case skipBackwardTapped
        case skipForwardTapped

        case speechEvent(ReaderSpeechClient.Event)
        case speechFailed(String)

        case rateChanged(Float)
        case voiceChanged(String?)
    }

    private enum CancelID {
        case speech
    }

    @Dependency(\.readerSpeechClient)
    var speechClient
    @Dependency(\.readerSpeechPreferencesClient)
    var preferencesClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadPreferences:
                let preferencesClient = self.preferencesClient
                return .run { send in
                    let prefs = preferencesClient.load()
                    await send(.preferencesLoaded(prefs))
                }

            case .preferencesLoaded(let prefs):
                state.selectedVoiceID = prefs.voiceID
                state.rate = max(0.2, min(prefs.rate, 2.0))
                return .none

            case .listenTapped(let blocks):
                guard !blocks.isEmpty else {
                    state.errorMessage = "Nothing to read."
                    return .none
                }

                state.errorMessage = nil
                state.isSpeaking = true
                state.isPaused = false
                state.currentBlockIndex = nil
                state.currentRangeInBlockUTF16 = nil
                state.currentSequence = nil
                state.currentBlocks = blocks

                // If the user hasn't picked a specific voice, resolve the best
                // installed Premium/Enhanced voice for their preferred language
                // each time. We don't store this back into state — keeping
                // `selectedVoiceID == nil` means "automatic" so a newly
                // downloaded better voice will be picked up next time.
                let resolvedVoiceID = state.selectedVoiceID ?? ReaderSpeechVoiceCatalog.bestDefaultVoiceID()

                let config = ReaderSpeechClient.Config(voiceID: resolvedVoiceID, rate: state.rate)
                let speechClient = self.speechClient
                return .run { send in
                    do {
                        for try await event in speechClient.start(blocks, config) {
                            await send(.speechEvent(event))
                        }
                    } catch {
                        await send(.speechFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.speech, cancelInFlight: true)

            case .pauseTapped:
                state.isPaused = true
                let speechClient = self.speechClient
                return .run { _ in
                    await speechClient.pause()
                }

            case .resumeTapped:
                state.isPaused = false
                let speechClient = self.speechClient
                return .run { _ in
                    await speechClient.resume()
                }

            case .stopTapped:
                state.isSpeaking = false
                state.isPaused = false
                state.currentBlockIndex = nil
                state.currentRangeInBlockUTF16 = nil
                state.currentSequence = nil
                state.currentBlocks = []
                let speechClient = self.speechClient
                return .run { _ in
                    await speechClient.stop()
                }
                .concatenate(with: .cancel(id: CancelID.speech))

            case .skipBackwardTapped:
                // Restart playback from the sentence immediately before
                // the one currently being spoken. `AVSpeechSynthesizer`
                // has no native seek API — the only way to "skip" is
                // stop, re-queue from the target unit, start again.
                // Filter by `sequence` (not `index`) so sentences from
                // the same paragraph are treated as distinct units.
                guard state.isSpeaking, !state.currentBlocks.isEmpty else {
                    return .none
                }
                let reference = state.currentSequence
                    ?? state.currentBlocks.first?.sequence
                    ?? 0
                let previous = state.currentBlocks.last { $0.sequence < reference }
                let targetSequence = previous?.sequence
                    ?? state.currentBlocks.first?.sequence
                    ?? reference
                let remaining = state.currentBlocks.filter { $0.sequence >= targetSequence }
                guard !remaining.isEmpty else { return .none }
                return .send(.listenTapped(blocks: remaining))

            case .skipForwardTapped:
                // Same mechanism as skipBackward but jumping to the
                // sentence immediately after the current one. If we're
                // already on the last sentence, drop into the normal
                // finish path via stopTapped — otherwise you'd end up
                // re-queuing the same sentence and hearing it repeat.
                guard state.isSpeaking, !state.currentBlocks.isEmpty else {
                    return .none
                }
                let reference = state.currentSequence
                    ?? state.currentBlocks.first?.sequence
                    ?? 0
                if let next = state.currentBlocks.first(where: { $0.sequence > reference }) {
                    let remaining = state.currentBlocks.filter { $0.sequence >= next.sequence }
                    return .send(.listenTapped(blocks: remaining))
                }
                return .send(.stopTapped)

            case .rateChanged(let value):
                state.rate = max(0.2, min(value, 2.0))
                let preferencesClient = self.preferencesClient
                let snapshot = ReaderSpeechPreferences(voiceID: state.selectedVoiceID, rate: state.rate)
                let saveEffect: EffectOf<Self> = .run { _ in
                    preferencesClient.save(snapshot)
                }

                // If playback is already underway, restart from the
                // currently-speaking sentence with the new rate. Queued
                // `AVSpeechUtterance`s bake their rate in at construction
                // time — there's no way to retune a utterance already in
                // the synthesizer's queue. Stop + re-queue is the only
                // path that actually lets the user hear the new rate.
                //
                // Restart from the current sentence so the listener
                // doesn't get thrown back to the top of the document
                // whenever they tap a speed button.
                if state.isSpeaking, !state.currentBlocks.isEmpty {
                    let resumeFrom = state.currentSequence
                        ?? state.currentBlocks.first?.sequence
                        ?? 0
                    let remaining = state.currentBlocks.filter { $0.sequence >= resumeFrom }
                    let blocksToReplay = remaining.isEmpty ? state.currentBlocks : remaining
                    return .merge(
                        saveEffect,
                        .send(.listenTapped(blocks: blocksToReplay))
                    )
                }
                return saveEffect

            case .voiceChanged(let id):
                state.selectedVoiceID = id
                let preferencesClient = self.preferencesClient
                let snapshot = ReaderSpeechPreferences(voiceID: state.selectedVoiceID, rate: state.rate)
                let saveEffect: EffectOf<Self> = .run { _ in
                    preferencesClient.save(snapshot)
                }

                // Same live-update rationale as `.rateChanged` — the new
                // voice only takes effect on utterances queued after it
                // changes, so mid-session voice swaps require stop +
                // re-queue from the current sentence.
                if state.isSpeaking, !state.currentBlocks.isEmpty {
                    let resumeFrom = state.currentSequence
                        ?? state.currentBlocks.first?.sequence
                        ?? 0
                    let remaining = state.currentBlocks.filter { $0.sequence >= resumeFrom }
                    let blocksToReplay = remaining.isEmpty ? state.currentBlocks : remaining
                    return .merge(
                        saveEffect,
                        .send(.listenTapped(blocks: blocksToReplay))
                    )
                }
                return saveEffect

            case .speechEvent(let event):
                switch event {
                case let .didStart(blockIndex, sequence):
                    state.currentBlockIndex = blockIndex
                    state.currentSequence = sequence
                    state.currentRangeInBlockUTF16 = nil
                    return .none

                case let .willSpeak(blockIndex, sequence, range):
                    state.currentBlockIndex = blockIndex
                    state.currentSequence = sequence
                    state.currentRangeInBlockUTF16 = range
                    return .none

                case .didFinishAll:
                    state.isSpeaking = false
                    state.isPaused = false
                    state.currentBlockIndex = nil
                    state.currentSequence = nil
                    state.currentRangeInBlockUTF16 = nil
                    return .cancel(id: CancelID.speech)

                case .didCancel:
                    state.isSpeaking = false
                    state.isPaused = false
                    state.currentBlockIndex = nil
                    state.currentSequence = nil
                    state.currentRangeInBlockUTF16 = nil
                    return .cancel(id: CancelID.speech)
                }

            case .speechFailed(let message):
                state.isSpeaking = false
                state.isPaused = false
                state.errorMessage = message
                state.currentBlockIndex = nil
                state.currentSequence = nil
                state.currentRangeInBlockUTF16 = nil
                return .cancel(id: CancelID.speech)
            }
        }
    }
}
