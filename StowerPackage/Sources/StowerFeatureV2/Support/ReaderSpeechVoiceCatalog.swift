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
        /// Siri's neural voices for the user's preferred languages. These
        /// are the most natural voices the system offers, so the picker
        /// leads with them and the automatic choice prefers them.
        var siriVoices = [VoiceEntry]()
        /// Languages matching the user's preferred languages, ordered by preference.
        let preferredGroups: [LanguageGroup]
        /// Everything else.
        let otherGroups: [LanguageGroup]
        /// True when none of the user's preferred languages have any Enhanced/Premium voices installed.
        let onlyDefaultQualityForPreferred: Bool

        var isEmpty: Bool { siriVoices.isEmpty && preferredGroups.isEmpty && otherGroups.isEmpty }
    }

    /// The facts about an installed voice the catalog needs, separated from
    /// `AVSpeechSynthesisVoice` so ranking can be tested without the system.
    struct VoiceInfo: Equatable {
        var identifier: String
        var name: String
        var language: String
        var quality: AVSpeechSynthesisVoiceQuality

        /// Siri's neural voices are published under this identifier prefix.
        /// The system tags them `.enhanced`, below the older `.premium`
        /// voices, even though they sound far more natural — so quality
        /// alone cannot be used to rank them.
        var isSiriVoice: Bool { identifier.hasPrefix("com.apple.siri.natural.") }
    }

    static func installedVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map {
            VoiceInfo(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality)
        }
    }

    static func loadCatalog() -> Catalog {
        makeCatalog(voices: installedVoices(), preferredLanguages: preferredLanguageSources())
    }

    static func makeCatalog(voices allVoices: [VoiceInfo], preferredLanguages: [String]) -> Catalog {
        let preferredPrefixes = languagePrefixes(from: preferredLanguages)

        func preferenceRank(_ voice: VoiceInfo) -> Int? {
            preferredPrefixes.firstIndex(of: String(voice.language.prefix(2)).lowercased())
        }
        let leadingSiri = allVoices.filter { $0.isSiriVoice && preferenceRank($0) != nil }
        let siriVoices = leadingSiri
            .sorted { lhs, rhs in
                let lhsRank = preferenceRank(lhs) ?? Int.max
                let rhsRank = preferenceRank(rhs) ?? Int.max
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { VoiceEntry(id: $0.identifier, displayName: displayName(for: $0), quality: $0.quality) }

        let groupsByLanguage = Dictionary(
            grouping: allVoices.filter { !leadingSiri.contains($0) },
            by: \.language
        )

        var preferred = [LanguageGroup]()
        var other = [LanguageGroup]()

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
            siriVoices: siriVoices,
            preferredGroups: preferred,
            otherGroups: other,
            onlyDefaultQualityForPreferred: onlyDefault && siriVoices.isEmpty
        )
    }

    /// Resolves the best installed voice for the user's preferred languages,
    /// preferring `.premium` then `.enhanced`. Returns `nil` to fall back to the
    /// system default (which is what `AVSpeechUtterance` picks when `voice` is unset).
    static func bestDefaultVoiceID() -> String? {
        bestDefaultVoiceID(voices: installedVoices(), preferredLanguages: preferredLanguageSources())
    }

    /// Siri's neural voice first, then `.premium`, then `.enhanced`.
    static func bestDefaultVoiceID(voices: [VoiceInfo], preferredLanguages: [String]) -> String? {
        for prefix in languagePrefixes(from: preferredLanguages) {
            let candidates = voices.filter { $0.language.lowercased().hasPrefix(prefix) }
            // Prefer the Siri voice for the user's exact region when there
            // are several for the language.
            let siri = candidates
                .filter(\.isSiriVoice)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let exactRegion = preferredLanguages.first { $0.lowercased().hasPrefix(prefix) }
            if let match = siri.first(where: { $0.language == exactRegion }) ?? siri.first {
                return match.identifier
            }
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

    private static func preferredLanguageSources() -> [String] {
        Locale.preferredLanguages.isEmpty ? [Locale.current.identifier] : Locale.preferredLanguages
    }

    private static func languagePrefixes(from sources: [String]) -> [String] {
        var seen = Set<String>()
        return sources.compactMap { source -> String? in
            let prefix = String(source.prefix(2)).lowercased()
            guard !prefix.isEmpty, seen.insert(prefix).inserted else { return nil }
            return prefix
        }
    }

    private static func displayName(for voice: VoiceInfo) -> String {
        if voice.isSiriVoice {
            // The system names these "Voice 1" … "Voice 5", matching
            // Settings → Siri → Siri Voice.
            return "Siri \(voice.name)"
        }
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
