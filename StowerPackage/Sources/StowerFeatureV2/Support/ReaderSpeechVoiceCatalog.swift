import AVFoundation
import Foundation

/// Builds the grouped, quality-aware voice list shown in the reader's voice picker
/// and resolves the best default voice for the user's preferred languages.
enum ReaderSpeechVoiceCatalog {
    struct VoiceEntry: Identifiable, Equatable {
        let id: String          // voice identifier
        let displayName: String // e.g. "Ava — Premium" or "Fred"
        let quality: AVSpeechSynthesisVoiceQuality
    }

    struct LanguageGroup: Identifiable, Equatable {
        let id: String          // BCP-47 language code, e.g. "en-US"
        let displayName: String // e.g. "English (United States)"
        let voices: [VoiceEntry]
    }

    struct Catalog: Equatable {
        /// Languages matching the user's preferred languages, ordered by preference.
        let preferredGroups: [LanguageGroup]
        /// Everything else.
        let otherGroups: [LanguageGroup]
        /// True when none of the user's preferred languages have any Enhanced/Premium voices installed.
        let onlyDefaultQualityForPreferred: Bool

        var isEmpty: Bool { preferredGroups.isEmpty && otherGroups.isEmpty }
    }

    static func loadCatalog() -> Catalog {
        let preferredPrefixes = preferredLanguagePrefixes()

        let groupsByLanguage = Dictionary(grouping: AVSpeechSynthesisVoice.speechVoices(), by: \.language)

        // swiftlint:disable prefer_let_over_var
        var preferred: [LanguageGroup] = []
        var other: [LanguageGroup] = []
        // swiftlint:enable prefer_let_over_var

        for (language, voices) in groupsByLanguage {
            let entries = voices
                .map { voice in
                    VoiceEntry(
                        id: voice.identifier,
                        displayName: displayName(for: voice),
                        quality: voice.quality
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.quality != rhs.quality {
                        return qualityRank(lhs.quality) > qualityRank(rhs.quality)
                    }
                    return lhs.displayName < rhs.displayName
                }

            let group = LanguageGroup(
                id: language,
                displayName: localizedLanguageName(for: language),
                voices: entries
            )

            let langPrefix = String(language.prefix(2)).lowercased()
            if preferredPrefixes.contains(langPrefix) {
                preferred.append(group)
            } else {
                other.append(group)
            }
        }

        // Order preferred groups to match the order of preferredPrefixes; ties broken by language code.
        preferred.sort { lhs, rhs in
            let lhsRank = preferredPrefixes.firstIndex(of: String(lhs.id.prefix(2)).lowercased()) ?? Int.max
            let rhsRank = preferredPrefixes.firstIndex(of: String(rhs.id.prefix(2)).lowercased()) ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.id < rhs.id
        }
        other.sort { $0.displayName < $1.displayName }

        let onlyDefault = !preferred.isEmpty && preferred.allSatisfy { group in
            group.voices.allSatisfy { $0.quality == .default }
        }

        return Catalog(
            preferredGroups: preferred,
            otherGroups: other,
            onlyDefaultQualityForPreferred: onlyDefault
        )
    }

    /// Resolves the best installed voice for the user's preferred languages,
    /// preferring `.premium` then `.enhanced`. Returns `nil` to fall back to the
    /// system default (which is what `AVSpeechUtterance` picks when `voice` is unset).
    static func bestDefaultVoiceID() -> String? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        for prefix in preferredLanguagePrefixes() {
            let candidates = voices.filter { $0.language.lowercased().hasPrefix(prefix) }
            if let premium = candidates.first(where: { $0.quality == .premium }) {
                return premium.identifier
            }
            if let enhanced = candidates.first(where: { $0.quality == .enhanced }) {
                return enhanced.identifier
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func preferredLanguagePrefixes() -> [String] {
        var seen = Set<String>()
        // swiftlint:disable:next prefer_let_over_var
        var result: [String] = []
        let sources = Locale.preferredLanguages.isEmpty
            ? [Locale.current.identifier]
            : Locale.preferredLanguages
        for source in sources {
            let prefix = String(source.prefix(2)).lowercased()
            if !prefix.isEmpty, seen.insert(prefix).inserted {
                result.append(prefix)
            }
        }
        return result
    }

    private static func displayName(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:
            return "\(voice.name) — Premium"
        case .enhanced:
            return "\(voice.name) — Enhanced"
        default:
            return voice.name
        }
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium:
            return 3
        case .enhanced:
            return 2
        default:
            return 1
        }
    }

    private static func localizedLanguageName(for languageCode: String) -> String {
        let locale = Locale.current
        if let name = locale.localizedString(forIdentifier: languageCode), !name.isEmpty {
            return name
        }
        return languageCode
    }
}
