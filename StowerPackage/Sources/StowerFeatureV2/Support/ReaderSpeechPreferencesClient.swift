import Dependencies
import Foundation

public struct ReaderSpeechPreferences: Equatable, Sendable {
    public var voiceID: String?
    public var rate: Float

    public init(voiceID: String? = nil, rate: Float = 1.0) {
        self.voiceID = voiceID
        self.rate = rate
    }
}

public struct ReaderSpeechPreferencesClient: Sendable {
    public var load: @Sendable () -> ReaderSpeechPreferences
    public var save: @Sendable (ReaderSpeechPreferences) -> Void
}

extension ReaderSpeechPreferencesClient {
    private enum Keys {
        static let voiceID = "stower.reader.speech.voiceID"
        static let rate = "stower.reader.speech.rate"
    }

    public static let live = ReaderSpeechPreferencesClient(
        load: {
            let defaults = UserDefaults.standard
            let voiceID = defaults.string(forKey: Keys.voiceID)
            let rawRate = defaults.object(forKey: Keys.rate) as? Double
            let rate = rawRate.map { Float($0) } ?? 1.0
            return ReaderSpeechPreferences(voiceID: voiceID, rate: rate)
        },
        save: { prefs in
            let defaults = UserDefaults.standard
            if let voiceID = prefs.voiceID {
                defaults.set(voiceID, forKey: Keys.voiceID)
            } else {
                defaults.removeObject(forKey: Keys.voiceID)
            }
            defaults.set(Double(prefs.rate), forKey: Keys.rate)
        }
    )

    public static let test = ReaderSpeechPreferencesClient(
        load: { ReaderSpeechPreferences() },
        save: { _ in }
    )
}

private enum ReaderSpeechPreferencesClientKey: DependencyKey {
    static let liveValue: ReaderSpeechPreferencesClient = .live
    static let testValue: ReaderSpeechPreferencesClient = .test
}

extension DependencyValues {
    var readerSpeechPreferencesClient: ReaderSpeechPreferencesClient {
        get { self[ReaderSpeechPreferencesClientKey.self] }
        set { self[ReaderSpeechPreferencesClientKey.self] = newValue }
    }
}
