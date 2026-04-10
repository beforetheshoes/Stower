import AVFoundation
import Dependencies
import Foundation

public struct ReaderSpeechClient: Sendable {
    public struct Config: Equatable, Sendable {
        var voiceID: String?
        // Interpreted as a multiplier on AVSpeechUtteranceDefaultSpeechRate.
        var rate: Float

        public init(voiceID: String? = nil, rate: Float = 1.0) {
            self.voiceID = voiceID
            self.rate = rate
        }
    }

    public enum Event: Equatable, Sendable {
        case didStart(blockIndex: Int)
        case willSpeak(blockIndex: Int, rangeInBlockUTF16: NSRange)
        case didFinishAll
        case didCancel
    }

    public var start: @Sendable (_ blocks: [SpeechBlock], _ config: Config) -> AsyncThrowingStream<Event, Error>
    public var pause: @Sendable () async -> Void
    public var resume: @Sendable () async -> Void
    public var stop: @Sendable () async -> Void
}

extension ReaderSpeechClient {
    public static let live: ReaderSpeechClient = {
        ReaderSpeechClient(
            start: { blocks, config in
                AsyncThrowingStream { continuation in
                    Task { @MainActor in
                        LiveReaderSpeechSynthDriverHolder.shared.start(
                            blocks: blocks,
                            config: config,
                            continuation: continuation
                        )
                    }
                }
            },
            pause: {
                await MainActor.run {
                    LiveReaderSpeechSynthDriverHolder.shared.pause()
                }
            },
            resume: {
                await MainActor.run {
                    LiveReaderSpeechSynthDriverHolder.shared.resume()
                }
            },
            stop: {
                await MainActor.run {
                    LiveReaderSpeechSynthDriverHolder.shared.stop()
                }
            }
        )
    }()

    public static let test: ReaderSpeechClient = ReaderSpeechClient(
        start: { _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        },
        pause: {},
        resume: {},
        stop: {}
    )
}

private enum ReaderSpeechClientKey: DependencyKey {
    static let liveValue: ReaderSpeechClient = .live
    static let testValue: ReaderSpeechClient = .test
}

extension DependencyValues {
    var readerSpeechClient: ReaderSpeechClient {
        get { self[ReaderSpeechClientKey.self] }
        set { self[ReaderSpeechClientKey.self] = newValue }
    }
}

@MainActor
private enum LiveReaderSpeechSynthDriverHolder {
    static let shared = LiveReaderSpeechSynthDriver()
}

@MainActor
private final class LiveReaderSpeechSynthDriver: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    private var continuation: AsyncThrowingStream<ReaderSpeechClient.Event, Error>.Continuation?
    private var utteranceToBlockIndex: [ObjectIdentifier: Int] = [:]
    private var isCancelled = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(
        blocks: [SpeechBlock],
        config: ReaderSpeechClient.Config,
        continuation: AsyncThrowingStream<ReaderSpeechClient.Event, Error>.Continuation
    ) {
        stop()

        isCancelled = false
        self.continuation = continuation
        utteranceToBlockIndex.removeAll(keepingCapacity: true)

        #if canImport(UIKit)
        configureAudioSessionForPlayback()
        #endif

        for block in blocks {
            let utterance = AVSpeechUtterance(string: block.text)

            if let voiceID = config.voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
                utterance.voice = voice
            }

            let targetRate = AVSpeechUtteranceDefaultSpeechRate * max(0.2, min(config.rate, 2.0))
            utterance.rate = min(max(targetRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)

            utteranceToBlockIndex[ObjectIdentifier(utterance)] = block.index
            synthesizer.speak(utterance)
        }

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    func pause() {
        _ = synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        _ = synthesizer.continueSpeaking()
    }

    func stop() {
        guard continuation != nil else {
            synthesizer.stopSpeaking(at: .immediate)
            utteranceToBlockIndex.removeAll()
            return
        }

        isCancelled = true
        synthesizer.stopSpeaking(at: .immediate)
        utteranceToBlockIndex.removeAll()

        continuation?.yield(.didCancel)
        continuation?.finish()
        continuation = nil
    }

    fileprivate func handleDidStart(utteranceID: ObjectIdentifier) {
        guard !isCancelled else { return }
        guard let index = utteranceToBlockIndex[utteranceID] else { return }
        continuation?.yield(.didStart(blockIndex: index))
    }

    fileprivate func handleWillSpeak(_ characterRange: NSRange, utteranceID: ObjectIdentifier) {
        guard !isCancelled else { return }
        guard let index = utteranceToBlockIndex[utteranceID] else { return }
        continuation?.yield(.willSpeak(blockIndex: index, rangeInBlockUTF16: characterRange))
    }

    fileprivate func handleDidFinish(utteranceID: ObjectIdentifier) {
        guard !isCancelled else { return }
        utteranceToBlockIndex[utteranceID] = nil

        if utteranceToBlockIndex.isEmpty {
            continuation?.yield(.didFinishAll)
            continuation?.finish()
            continuation = nil
        }
    }

    #if canImport(UIKit)
    private func configureAudioSessionForPlayback() {
        // Keep it simple for MVP: speak even with the silent switch and in the background.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Non-fatal for MVP.
        }
    }
    #endif
}

extension LiveReaderSpeechSynthDriver: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleDidStart(utteranceID: id)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleWillSpeak(characterRange, utteranceID: id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleDidFinish(utteranceID: id)
        }
    }
}
