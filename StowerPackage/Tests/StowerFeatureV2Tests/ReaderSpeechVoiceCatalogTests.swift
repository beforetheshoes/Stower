import AVFoundation
@testable import StowerFeature
import Testing

@Suite
struct ReaderSpeechVoiceCatalogTests {
    private typealias Voice = ReaderSpeechVoiceCatalog.VoiceInfo

    private let siriUS = Voice(
        identifier: "com.apple.siri.natural.Nora", name: "Voice 4", language: "en-US", quality: .enhanced
    )
    private let siriES = Voice(
        identifier: "com.apple.siri.natural.Luisa", name: "Voice 2", language: "es-ES", quality: .enhanced
    )
    private let premium = Voice(
        identifier: "com.apple.voice.premium.en-US.Zoe", name: "Zoe (Premium)", language: "en-US", quality: .premium
    )
    private let enhanced = Voice(
        identifier: "com.apple.voice.enhanced.en-US.Evan", name: "Evan", language: "en-US", quality: .enhanced
    )
    private let compact = Voice(
        identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .default
    )

    @Test
    func automaticVoicePrefersSiriOverPremium() {
        // The system tags Siri's neural voices `.enhanced`, below `.premium`.
        let id = ReaderSpeechVoiceCatalog.bestDefaultVoiceID(
            voices: [compact, premium, enhanced, siriUS],
            preferredLanguages: ["en-US"]
        )
        #expect(id == siriUS.identifier)
    }

    @Test
    func automaticVoiceFallsBackToPremiumThenEnhanced() {
        #expect(
            ReaderSpeechVoiceCatalog.bestDefaultVoiceID(
                voices: [compact, enhanced, premium], preferredLanguages: ["en-US"]
            ) == premium.identifier
        )
        #expect(
            ReaderSpeechVoiceCatalog.bestDefaultVoiceID(
                voices: [compact, enhanced], preferredLanguages: ["en-US"]
            ) == enhanced.identifier
        )
        #expect(
            ReaderSpeechVoiceCatalog.bestDefaultVoiceID(
                voices: [compact], preferredLanguages: ["en-US"]
            ) == nil
        )
    }

    @Test
    func automaticVoiceIgnoresSiriVoicesForOtherLanguages() {
        let id = ReaderSpeechVoiceCatalog.bestDefaultVoiceID(
            voices: [siriES, premium],
            preferredLanguages: ["en-US"]
        )
        #expect(id == premium.identifier)
    }

    @Test
    func catalogLeadsWithSiriVoicesForPreferredLanguages() {
        let catalog = ReaderSpeechVoiceCatalog.makeCatalog(
            voices: [compact, premium, siriUS, siriES],
            preferredLanguages: ["en-US"]
        )
        #expect(catalog.siriVoices.map(\.id) == [siriUS.identifier])
        #expect(catalog.siriVoices.first?.displayName == "Siri Voice 4")
        // The Siri voice is not repeated inside its language group.
        let grouped = catalog.preferredGroups.flatMap(\.voices).map(\.id)
        #expect(grouped == [premium.identifier, compact.identifier])
        // A Siri voice for a non-preferred language stays with that language.
        #expect(catalog.otherGroups.flatMap(\.voices).map(\.id) == [siriES.identifier])
        #expect(!catalog.onlyDefaultQualityForPreferred)
    }
}
