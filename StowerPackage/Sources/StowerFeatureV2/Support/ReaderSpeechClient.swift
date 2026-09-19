import AVFoundation
import Dependencies
import Foundation

public struct ReaderSpeechClient: Sendable {
    public struct Config: Equatable, Sendable {
        var voice: ReaderSpeechVoice
        /// Playback speed multiplier, where 1.0 is the voice's natural pace.
        var rate: Float

        public init(voice: ReaderSpeechVoice = .default, rate: Float = 1.0) {
            self.voice = voice
            self.rate = rate
        }
    }

    public enum Event: Equatable, Sendable {
        /// The voice model is being downloaded or loaded; nothing is audible yet.
        case preparingVoice
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
                    @Dependency(\.neuralSpeechEngine)
                    var engine
                    Task { @MainActor in
                        NeuralReaderSpeechDriverHolder.shared.start(
                            blocks: blocks,
                            config: config,
                            engine: engine,
                            continuation: continuation
                        )
                    }
                }
            },
            pause: {
                await MainActor.run {
                    NeuralReaderSpeechDriverHolder.shared.pause()
                }
            },
            resume: {
                await MainActor.run {
                    NeuralReaderSpeechDriverHolder.shared.resume()
                }
            },
            stop: {
                await MainActor.run {
                    NeuralReaderSpeechDriverHolder.shared.stop()
                }
            }
        )
    }()

    public static let test = ReaderSpeechClient(
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
private enum NeuralReaderSpeechDriverHolder {
    static let shared = NeuralReaderSpeechDriver()
}

/// Plays a queue of speech units through `AVAudioEngine`, synthesizing each
/// with the neural engine a little ahead of playback so narration starts
/// after one sentence's worth of work and never stalls between sentences.
@MainActor
private final class NeuralReaderSpeechDriver {
    /// How many upcoming units are synthesized while the current one plays.
    private static let lookAhead = 2

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedSampleRate: Double?

    private var continuation: AsyncThrowingStream<ReaderSpeechClient.Event, Error>.Continuation?
    /// Identifies the current playback run. Anything that outlives its run
    /// (a late callback, a stream termination) checks this before acting.
    private var session: UUID?
    private var playbackTask: Task<Void, Never>?
    private var prefetch = [Int: Task<SpeechAudio, Error>]()
    private var isPaused = false

    init() {
        audioEngine.attach(player)
    }

    func start(
        blocks: [SpeechBlock],
        config: ReaderSpeechClient.Config,
        engine: NeuralSpeechEngineClient,
        continuation: AsyncThrowingStream<ReaderSpeechClient.Event, Error>.Continuation
    ) {
        stop()

        let runID = UUID()
        session = runID
        isPaused = false
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == runID else { return }
                self.stop()
            }
        }

        playbackTask = Task { [weak self] in
            await self?.run(blocks: blocks, config: config, engine: engine, runID: runID)
        }
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        if audioEngine.isRunning {
            player.play()
        }
    }

    func stop() {
        let hadSession = session != nil
        session = nil
        playbackTask?.cancel()
        playbackTask = nil
        for task in prefetch.values {
            task.cancel()
        }
        prefetch.removeAll()
        player.stop()
        audioEngine.stop()

        if hadSession {
            continuation?.yield(.didCancel)
        }
        continuation?.finish()
        continuation = nil
    }

    private func run(
        blocks: [SpeechBlock],
        config: ReaderSpeechClient.Config,
        engine: NeuralSpeechEngineClient,
        runID: UUID
    ) async {
        let speed = max(0.5, min(config.rate, 2.0))
        do {
            if await !engine.isReady() {
                continuation?.yield(.preparingVoice)
            }
            try await engine.prepare()
            guard session == runID else { return }

            #if canImport(UIKit)
            configureAudioSessionForPlayback()
            #endif

            for index in blocks.indices {
                guard session == runID else { return }

                // Keep the next few units in flight while this one plays.
                let upperBound = min(index + Self.lookAhead, blocks.count - 1)
                for upcoming in index...upperBound where prefetch[upcoming] == nil {
                    let text = blocks[upcoming].text
                    prefetch[upcoming] = Task {
                        try await engine.synthesize(text, config.voice, speed)
                    }
                }

                guard let pending = prefetch[index] else { continue }
                let audio = try await pending.value
                prefetch[index] = nil
                guard session == runID else { return }
                guard let buffer = Self.makeBuffer(from: audio) else { continue }

                try startEngineIfNeeded(sampleRate: audio.sampleRate)
                continuation?.yield(
                    .didStart(blockIndex: blocks[index].index, sequence: blocks[index].sequence)
                )
                await play(buffer)
            }

            guard session == runID else { return }
            session = nil
            player.stop()
            audioEngine.stop()
            continuation?.yield(.didFinishAll)
            continuation?.finish()
            continuation = nil
        } catch is CancellationError {
            return
        } catch {
            guard session == runID else { return }
            session = nil
            player.stop()
            audioEngine.stop()
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

    /// Schedules one buffer and returns once it has been heard (or playback
    /// was stopped). While paused the player holds the buffer, so this simply
    /// keeps waiting.
    private func play(_ buffer: AVAudioPCMBuffer) async {
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                finished.resume()
            }
            if !isPaused {
                player.play()
            }
        }
    }

    private func startEngineIfNeeded(sampleRate: Double) throws {
        if connectedSampleRate != sampleRate {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                return
            }
            audioEngine.stop()
            audioEngine.disconnectNodeOutput(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
            connectedSampleRate = sampleRate
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private static func makeBuffer(from audio: SpeechAudio) -> AVAudioPCMBuffer? {
        guard !audio.samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(audio.samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        return buffer
    }

    #if canImport(UIKit)
    private func configureAudioSessionForPlayback() {
        // Speak even with the silent switch on, and duck other audio.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Non-fatal: playback still works with the default session.
        }
    }
    #endif
}
