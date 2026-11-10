import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct SettingsFeatureTests {
    private struct Failure: Error, LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    @Test
    func loadShowsStoredSettings() async {
        let stored = ImageDownloadSettings(globalAutoDownload: true, askForNewSources: false)
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.loadSettings = { stored }
            $0.syncDiagnosticsClient = .noop
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.load)
        await store.receive(.response(stored)) {
            $0.settings = stored
            $0.errorMessage = nil
        }
        await store.finish()
    }

    @Test
    func loadFailureIsShown() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.loadSettings = { throw Failure() }
        }

        await store.send(.load)
        await store.receive(.failed("disk full")) {
            $0.errorMessage = "disk full"
        }
    }

    @Test
    func changingAToggleSavesTheNewSettings() async {
        let saved = LockIsolated<[ImageDownloadSettings]>([])
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.saveSettings = { settings in saved.withValue { $0.append(settings) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.globalAutoDownloadChanged(true)) {
            $0.settings.globalAutoDownload = true
        }
        await store.receive(.save)
        await store.receive(.saveFinished)

        await store.send(.askForNewSourcesChanged(false)) {
            $0.settings.askForNewSources = false
        }
        await store.receive(.save)
        await store.receive(.saveFinished)

        #expect(saved.value.count == 2)
        #expect(saved.value.last?.globalAutoDownload == true)
        #expect(saved.value.last?.askForNewSources == false)
    }

    @Test
    func saveFailureIsShownAndTheChoiceIsKept() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.stowerRepository.saveSettings = { _ in throw Failure() }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.globalAutoDownloadChanged(true)) {
            $0.settings.globalAutoDownload = true
        }
        await store.receive(.saveFailed("disk full")) {
            $0.errorMessage = "disk full"
        }
        #expect(store.state.settings.globalAutoDownload)
    }
}
