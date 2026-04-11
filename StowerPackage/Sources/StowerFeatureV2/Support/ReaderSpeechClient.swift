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
        case didStart(blockIndex: Int, sequence: Int)
        case willSpeak(blockIndex: Int, sequence: Int, rangeInBlockUTF16: NSRange)
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
    /// Maps a queued `AVSpeechUtterance`'s object identity to its
    /// position in the original speech plan. Each entry records both
    /// the document block index (used by the reader for scroll and
    /// highlight routing) and the monotonic sequence number (used by
    /// the feature's skip forward/backward buttons to advance one
    /// sentence at a time without conflating sentences that share a
    /// block index).
    private struct UtterancePosition {
        let blockIndex: Int
        let sequence: Int
    }
    private var utteranceToPosition: [ObjectIdentifier: UtterancePosition] = [:]
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
        utteranceToPosition.removeAll(keepingCapacity: true)

        #if canImport(UIKit)
        configureAudioSessionForPlayback()
        #endif

        for block in blocks {
            let utterance = AVSpeechUtterance(string: block.text)

            if let voiceID = config.voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
                utterance.voice = voice
            }

            utterance.rate = Self.avSpeechRate(fromMultiplier: config.rate)

            utteranceToPosition[ObjectIdentifier(utterance)] = UtterancePosition(
                blockIndex: block.index,
                sequence: block.sequence
            )
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
            utteranceToPosition.removeAll()
            return
        }

        isCancelled = true
        synthesizer.stopSpeaking(at: .immediate)
        utteranceToPosition.removeAll()

        continuation?.yield(.didCancel)
        continuation?.finish()
        continuation = nil
    }

    fileprivate func handleDidStart(utteranceID: ObjectIdentifier) {
        guard !isCancelled else { return }
        guard let position = utteranceToPosition[utteranceID] else { return }
        continuation?.yield(
            .didStart(blockIndex: position.blockIndex, sequence: position.sequence)
        )
    }

    fileprivate func handleWillSpeak(_ characterRange: NSRange, utteranceID: ObjectIdentifier) {
        guard !isCancelled else { return }
        guard let position = utteranceToPosition[utteranceID] else { return }
        continuation?.yield(
            .willSpeak(
                blockIndex: position.blockIndex,
                sequence: position.sequence,
                rangeInBlockUTF16: characterRange
            )
        )
    }

    fileprivate func handleDidFinish(utteranceID: ObjectIdentifier) {
        guard !isCancelled else { return }
        utteranceToPosition[utteranceID] = nil

        if utteranceToPosition.isEmpty {
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

    /// Maps a user-facing speed multiplier (0.5x..2.0x) onto
    /// `AVSpeechUtterance.rate`, whose axis is `[0.0, 1.0]` with `0.5`
    /// at the system default and is aggressively non-linear — setting
    /// `rate = 1.0` (maximum) produces roughly 3–4x the default
    /// perceptual speed, not 2x. The previous implementation was a
    /// straight `default * multiplier` multiplication, which mapped
    /// "1.5x" onto `rate = 0.75` and sounded like ~3x. This piecewise
    /// linear mapping keeps each step of the speed picker close to its
    /// label:
    ///
    /// ```
    /// 0.5x → 0.42
    /// 0.75x → 0.46
    /// 1.0x → 0.50  (default)
    /// 1.25x → 0.53
    /// 1.5x → 0.56
    /// 1.75x → 0.59
    /// 2.0x → 0.62
    /// ```
    ///
    /// Final clamp against `AVSpeechUtteranceMinimumSpeechRate` /
    /// `AVSpeechUtteranceMaximumSpeechRate` keeps us inside the legal
    /// rate range even if the upstream multiplier somehow escapes its
    /// clamp.
    fileprivate static func avSpeechRate(fromMultiplier multiplier: Float) -> Float {
        let clamped = max(0.2, min(multiplier, 2.0))
        let raw: Float
        if clamped < 1.0 {
            // 0.5x → 0.42, 1.0x → 0.50
            raw = 0.42 + (clamped - 0.5) * 0.16
        } else {
            // 1.0x → 0.50, 2.0x → 0.62
            raw = 0.50 + (clamped - 1.0) * 0.12
        }
        return min(
            max(raw, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
    }
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
