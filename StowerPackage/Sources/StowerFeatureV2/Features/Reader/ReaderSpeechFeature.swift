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

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
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

                let config = ReaderSpeechClient.Config(voiceID: state.selectedVoiceID, rate: state.rate)
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
                return .none

            case .voiceChanged(let id):
                state.selectedVoiceID = id
                return .none

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
