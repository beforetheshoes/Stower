import Foundation

/// The narration voices offered in Listen mode. Each is a Kokoro voice pack,
/// downloaded the first time it is used.
public enum ReaderSpeechVoice: String, CaseIterable, Identifiable, Sendable {
    case heart = "af_heart"
    case bella = "af_bella"
    case michael = "am_michael"
    case george = "bm_george"

    public static let `default` = ReaderSpeechVoice.heart

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .heart:
            "Heart"
        case .bella:
            "Bella"
        case .michael:
            "Michael"
        case .george:
            "George (British)"
        }
    }

    /// Resolves a stored preference. Preferences saved by earlier builds hold
    /// system voice identifiers, which fall back to the default voice.
    public static func resolve(_ storedID: String?) -> ReaderSpeechVoice {
        storedID.flatMap(ReaderSpeechVoice.init(rawValue:)) ?? .default
    }
}
