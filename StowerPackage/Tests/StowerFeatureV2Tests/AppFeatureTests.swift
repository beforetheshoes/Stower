import ComposableArchitecture
import Foundation
import Testing
@testable import StowerFeature

@MainActor
@Suite
struct AppFeatureTests {
    @Test
    func startupLoadsLibraryAndSettings() async {
        let item = SavedItem(id: UUID(), title: "One", content: "Body")
        let settings = ImageDownloadSettings(globalAutoDownload: true, askForNewSources: false)

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.cloudSyncClient = CloudSyncClient(start: {}, sendChanges: {})
            $0.stowerRepository.fetchPendingIngestionJobs = { [] }
            $0.stowerRepository.fetchLibrary = { [item] }
            $0.stowerRepository.loadSettings = { settings }
        }

        await store.send(AppFeature.Action.onAppear)
        await store.receive(AppFeature.Action.startupFinished) {
            $0.startupFinished = true
        }
        await store.receive(AppFeature.Action.library(.reload)) {
            $0.library.isLoading = true
        }
        await store.receive(AppFeature.Action.settings(.load))
        await store.receive(AppFeature.Action.library(.response([item]))) {
            $0.library.items = [item]
            $0.library.isLoading = false
        }
        await store.receive(AppFeature.Action.settings(.response(settings))) {
            $0.settings.settings = settings
        }
    }
}
