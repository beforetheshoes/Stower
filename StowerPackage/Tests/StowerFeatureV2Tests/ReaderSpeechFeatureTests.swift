import ComposableArchitecture
import Foundation
import Testing
@testable import StowerFeature

@MainActor
@Suite
struct ReaderSpeechFeatureTests {
    @Test
    func listen_updatesHighlightFromEvents_andFinishes() async {
        // `sequence` defaults to `index` when constructed with only the
        // index argument, so this block has sequence == 1 too.
        let blocks = [SpeechBlock(index: 1, kind: .paragraph, text: "Hello world")]

        let client = ReaderSpeechClient(
            start: { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.didStart(blockIndex: 1, sequence: 1))
                    continuation.yield(
                        .willSpeak(
                            blockIndex: 1,
                            sequence: 1,
                            rangeInBlockUTF16: NSRange(location: 0, length: 5)
                        )
                    )
                    continuation.yield(.didFinishAll)
                    continuation.finish()
                }
            },
            pause: {},
            resume: {},
            stop: {}
        )

        let store = TestStore(initialState: ReaderSpeechFeature.State()) {
            ReaderSpeechFeature()
        } withDependencies: {
            $0.readerSpeechClient = client
        }

        await store.send(.listenTapped(blocks: blocks)) {
            $0.isSpeaking = true
            $0.isPaused = false
            $0.errorMessage = nil
            $0.currentBlockIndex = nil
            $0.currentSequence = nil
            $0.currentRangeInBlockUTF16 = nil
            $0.currentBlocks = blocks
        }

        await store.receive(.speechEvent(.didStart(blockIndex: 1, sequence: 1))) {
            $0.currentBlockIndex = 1
            $0.currentSequence = 1
            $0.currentRangeInBlockUTF16 = nil
        }

        await store.receive(
            .speechEvent(
                .willSpeak(
                    blockIndex: 1,
                    sequence: 1,
                    rangeInBlockUTF16: NSRange(location: 0, length: 5)
                )
            )
        ) {
            $0.currentBlockIndex = 1
            $0.currentSequence = 1
            $0.currentRangeInBlockUTF16 = NSRange(location: 0, length: 5)
        }

        await store.receive(.speechEvent(.didFinishAll)) {
            $0.isSpeaking = false
            $0.isPaused = false
            $0.currentBlockIndex = nil
            $0.currentSequence = nil
            $0.currentRangeInBlockUTF16 = nil
        }
    }

    @Test
    func stop_resetsState_andCallsStop() async {
        let stopCalled = LockIsolated(false)

        let client = ReaderSpeechClient(
            start: { _, _ in
                AsyncThrowingStream { _ in
                    // Keep the stream open until cancellation.
                }
            },
            pause: {},
            resume: {},
            stop: {
                stopCalled.withValue { $0 = true }
            }
        )

        let store = TestStore(
            initialState: ReaderSpeechFeature.State(
                isSpeaking: true,
                currentBlockIndex: 2,
                currentRangeInBlockUTF16: NSRange(location: 1, length: 2),
                currentSequence: 2
            )
        ) {
            ReaderSpeechFeature()
        } withDependencies: {
            $0.readerSpeechClient = client
        }

        await store.send(.stopTapped) {
            $0.isSpeaking = false
            $0.isPaused = false
            $0.currentBlockIndex = nil
            $0.currentRangeInBlockUTF16 = nil
            $0.currentSequence = nil
        }

        #expect(stopCalled.value == true)
    }
}

