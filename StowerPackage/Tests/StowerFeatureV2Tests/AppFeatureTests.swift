import ComposableArchitecture
import Foundation
import Testing
@testable import StowerData
@testable import StowerFeature

@MainActor
@Suite
struct AppFeatureTests {
    @Test
    func saveURL_thenOpenItem_readerLoadsSuccessfully() async throws {
        // Use a REAL database to test the full flow
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        // 1) Create item via the repository (same as saveURLTapped does)
        let ingestion = IngestionResult.sharedText("Hello from the full flow test")
        let created = try await repository.createItemFromIngestion(ingestion)

        // 2) Verify fetchLibrary returns it
        let library = try await repository.fetchLibrary(.all)
        #expect(library.contains(where: { $0.id == created.id }))

        // 3) Test the reader load flow with TCA
        let store = TestStore(initialState: ReaderFeature.State(itemID: created.id)) {
            ReaderFeature()
        } withDependencies: {
            $0.stowerRepository = repository
            $0.urlIngestionClient = .failing
            $0.continuousClock = ImmediateClock()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.load) {
            $0.isLoading = true
        }
        await store.receive(\.loaded) {
            $0.isLoading = false
            // The item MUST not be nil — nil is what causes "Item not found"
            #expect($0.item != nil, "loadItem returned nil — this causes 'Item not found'")
            #expect($0.item?.id == created.id)
            #expect($0.item?.title == "Shared Note")
            #expect($0.document != nil)
        }
    }

    @Test
    func startupLoadsLibraryAndSettings() async {
        let item = SavedItem(id: UUID(), title: "One", content: "Body")
        let settings = ImageDownloadSettings(globalAutoDownload: true, askForNewSources: false)
        let appearance = ReaderAppearanceSettings(background: .sepia)

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.cloudSyncClient = CloudSyncClient(
                start: {},
                sendChanges: {},
                scheduleSendChanges: {},
                statusStream: { AsyncStream { continuation in continuation.finish() } }
            )
            $0.stowerRepository.fetchPendingIngestionJobs = { [] }
            $0.stowerRepository.fetchLibrary = { _ in [item] }
            $0.stowerRepository.fetchListCounts = { .zero }
            $0.stowerRepository.fetchTags = { [] }
            $0.stowerRepository.observeLibraryChanges = { AsyncStream { $0.finish() } }
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.loadSettings = { settings }
            $0.stowerRepository.loadReaderAppearanceSettings = { appearance }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.continuousClock = ImmediateClock()
            $0.syncDiagnosticsClient = .noop
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(AppFeature.Action.onAppear)

        // Appearance loads in parallel — may arrive before or after startup
        await store.receive(AppFeature.Action.readerAppearanceLoaded(appearance)) {
            $0.cachedAppearance = appearance
        }
        await store.receive(AppFeature.Action.startupFinished) {
            $0.startupFinished = true
        }

        await store.finish()
    }
}
