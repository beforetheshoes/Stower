import Dependencies
import FluidAudio
import Foundation

/// Mono PCM audio for one spoken unit.
public struct SpeechAudio: Equatable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// The on-device neural text-to-speech engine that powers Listen mode.
///
/// Apple does not give third-party apps Siri's voices on iOS, and the voices
/// it does provide sound synthetic, so narration runs through Kokoro on Core
/// ML instead. The model is downloaded once, on first use, and everything
/// after that works offline.
public struct NeuralSpeechEngineClient: Sendable {
    /// Whether the model is already loaded in memory.
    public var isReady: @Sendable () async -> Bool
    /// Downloads the model if needed and loads it. Safe to call repeatedly.
    public var prepare: @Sendable () async throws -> Void
    public var synthesize: @Sendable (
        _ text: String,
        _ voice: ReaderSpeechVoice,
        _ speed: Float
    ) async throws -> SpeechAudio

    public init(
        isReady: @escaping @Sendable () async -> Bool,
        prepare: @escaping @Sendable () async throws -> Void,
        synthesize: @escaping @Sendable (String, ReaderSpeechVoice, Float) async throws -> SpeechAudio
    ) {
        self.isReady = isReady
        self.prepare = prepare
        self.synthesize = synthesize
    }
}

extension NeuralSpeechEngineClient {
    public static var live: NeuralSpeechEngineClient {
        let manager = KokoroAneManager(
            defaultVoice: ReaderSpeechVoice.default.rawValue,
            directory: modelsDirectory()
        )
        return NeuralSpeechEngineClient(
            isReady: { await manager.isAvailable() },
            prepare: { try await manager.initialize() },
            synthesize: { text, voice, speed in
                let result = try await manager.synthesizeDetailed(
                    text: text,
                    voice: voice.rawValue,
                    speed: speed
                )
                return SpeechAudio(samples: result.samples, sampleRate: Double(result.sampleRate))
            }
        )
    }

    /// Silent, instant engine for tests and previews.
    public static var noop: NeuralSpeechEngineClient {
        NeuralSpeechEngineClient(
            isReady: { true },
            prepare: {},
            synthesize: { _, _, _ in SpeechAudio(samples: [], sampleRate: 24_000) }
        )
    }

    /// Models live in Application Support and are excluded from backups: they
    /// are large and can always be downloaded again.
    private static func modelsDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        else { return nil }
        var directory = support.appendingPathComponent("SpeechModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }
}

private enum NeuralSpeechEngineClientKey: DependencyKey {
    static let liveValue: NeuralSpeechEngineClient = .live
    static var testValue: NeuralSpeechEngineClient { .noop }
    static var previewValue: NeuralSpeechEngineClient { .noop }
}

extension DependencyValues {
    public var neuralSpeechEngine: NeuralSpeechEngineClient {
        get { self[NeuralSpeechEngineClientKey.self] }
        set { self[NeuralSpeechEngineClientKey.self] = newValue }
    }
}
