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

        var errorMessage: String?
    }

    public enum Action: Equatable {
        case loadPreferences
        case preferencesLoaded(ReaderSpeechPreferences)

        case listenTapped(blocks: [SpeechBlock])
        case pauseTapped
        case resumeTapped
        case stopTapped

        case speechEvent(ReaderSpeechClient.Event)
        case speechFailed(String)

        case rateChanged(Float)
        case voiceChanged(String?)
    }

    private enum CancelID {
        case speech
    }

    @Dependency(\.readerSpeechClient) var speechClient
    @Dependency(\.readerSpeechPreferencesClient) var preferencesClient

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
                let speechClient = self.speechClient
                return .run { _ in
                    await speechClient.stop()
                }
                .concatenate(with: .cancel(id: CancelID.speech))

            case .rateChanged(let value):
                state.rate = max(0.2, min(value, 2.0))
                let preferencesClient = self.preferencesClient
                let snapshot = ReaderSpeechPreferences(voiceID: state.selectedVoiceID, rate: state.rate)
                return .run { _ in
                    preferencesClient.save(snapshot)
                }

            case .voiceChanged(let id):
                state.selectedVoiceID = id
                let preferencesClient = self.preferencesClient
                let snapshot = ReaderSpeechPreferences(voiceID: state.selectedVoiceID, rate: state.rate)
                return .run { _ in
                    preferencesClient.save(snapshot)
                }

            case .speechEvent(let event):
                switch event {
                case .didStart(let blockIndex):
                    state.currentBlockIndex = blockIndex
                    state.currentRangeInBlockUTF16 = nil
                    return .none

                case .willSpeak(let blockIndex, let range):
                    state.currentBlockIndex = blockIndex
                    state.currentRangeInBlockUTF16 = range
                    return .none

                case .didFinishAll:
                    state.isSpeaking = false
                    state.isPaused = false
                    state.currentBlockIndex = nil
                    state.currentRangeInBlockUTF16 = nil
                    return .cancel(id: CancelID.speech)

                case .didCancel:
                    state.isSpeaking = false
                    state.isPaused = false
                    state.currentBlockIndex = nil
                    state.currentRangeInBlockUTF16 = nil
                    return .cancel(id: CancelID.speech)
                }

            case .speechFailed(let message):
                state.isSpeaking = false
                state.isPaused = false
                state.errorMessage = message
                state.currentBlockIndex = nil
                state.currentRangeInBlockUTF16 = nil
                return .cancel(id: CancelID.speech)
            }
        }
    }
}
