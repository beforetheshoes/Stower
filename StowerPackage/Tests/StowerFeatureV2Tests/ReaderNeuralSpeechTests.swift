import ComposableArchitecture
import Foundation
@testable import StowerFeature
import Testing

@Suite
struct ReaderNeuralSpeechTests {
    @Test
    func storedSystemVoiceIdentifiersFallBackToTheDefaultVoice() {
        #expect(ReaderSpeechVoice.resolve(nil) == .heart)
        #expect(ReaderSpeechVoice.resolve("com.apple.voice.premium.en-US.Zoe") == .heart)
        #expect(ReaderSpeechVoice.resolve("bm_george") == .george)
    }

    @MainActor
    @Test
    func listeningUsesTheChosenVoiceAndShowsPreparationUntilAudioStarts() async {
        let configs = LockIsolated<[ReaderSpeechClient.Config]>([])
        let (events, continuation) = AsyncThrowingStream<ReaderSpeechClient.Event, Error>.makeStream()
        let block = SpeechBlock(index: 3, kind: .paragraph, text: "Hello there.", sequence: 0)

        var state = ReaderSpeechFeature.State()
        state.selectedVoiceID = ReaderSpeechVoice.bella.rawValue
        state.rate = 1.2
        let store = TestStore(initialState: state) {
            ReaderSpeechFeature()
        } withDependencies: {
            $0.readerSpeechClient.start = { _, config in
                configs.withValue { $0.append(config) }
                return events
            }
        }

        await store.send(.listenTapped(blocks: [block])) {
            $0.isSpeaking = true
            $0.currentBlocks = [block]
        }
        #expect(configs.value == [ReaderSpeechClient.Config(voice: .bella, rate: 1.2)])

        continuation.yield(.preparingVoice)
        await store.receive(.speechEvent(.preparingVoice)) {
            $0.isPreparingVoice = true
        }

        continuation.yield(.didStart(blockIndex: 3, sequence: 0))
        await store.receive(.speechEvent(.didStart(blockIndex: 3, sequence: 0))) {
            $0.isPreparingVoice = false
            $0.currentBlockIndex = 3
            $0.currentSequence = 0
        }

        continuation.yield(.didFinishAll)
        await store.receive(.speechEvent(.didFinishAll)) {
            $0.isSpeaking = false
            $0.currentBlockIndex = nil
            $0.currentSequence = nil
        }
        continuation.finish()
    }

    @MainActor
    @Test
    func aFailedVoiceDownloadClearsThePreparingState() async {
        struct Offline: Error, LocalizedError {
            var errorDescription: String? { "The voice could not be downloaded." }
        }
        let block = SpeechBlock(index: 0, kind: .paragraph, text: "Hello.")
        let store = TestStore(initialState: ReaderSpeechFeature.State()) {
            ReaderSpeechFeature()
        } withDependencies: {
            $0.readerSpeechClient.start = { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.preparingVoice)
                    continuation.finish(throwing: Offline())
                }
            }
        }

        await store.send(.listenTapped(blocks: [block])) {
            $0.isSpeaking = true
            $0.currentBlocks = [block]
        }
        await store.receive(.speechEvent(.preparingVoice)) {
            $0.isPreparingVoice = true
        }
        await store.receive(.speechFailed("The voice could not be downloaded.")) {
            $0.isSpeaking = false
            $0.isPreparingVoice = false
            $0.errorMessage = "The voice could not be downloaded."
        }
    }
}

/// Exercises the real Kokoro engine. Opt-in because the first run downloads
/// the model (about 100 MB): `STOWER_RUN_NEURAL_SPEECH_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOWER_RUN_NEURAL_SPEECH_TESTS"] == "1"))
struct NeuralSpeechEngineIntegrationTests {
    @Test
    func liveEngineSynthesizesAudibleSpeech() async throws {
        let engine = NeuralSpeechEngineClient.live
        try await engine.prepare()
        #expect(await engine.isReady())

        let normal = try await engine.synthesize("Stower reads this sentence aloud.", .heart, 1.0)
        #expect(normal.sampleRate == 24_000)
        #expect(normal.samples.count > 12_000)
        #expect(normal.samples.contains { abs($0) > 0.01 })

        // A higher speed yields a shorter clip for the same text.
        let fast = try await engine.synthesize("Stower reads this sentence aloud.", .heart, 1.5)
        #expect(fast.samples.count < normal.samples.count)
    }
}
