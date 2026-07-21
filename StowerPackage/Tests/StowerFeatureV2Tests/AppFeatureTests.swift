import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct AppFeatureTests {
    @Test
    func doneDismissesReaderButKeepsItemAvailableForUndo() async {
        let item = SavedItem(title: "Reference", content: "Body")
        let writes = LockIsolated<[Bool]>([])
        let clock = TestClock()
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: item, appearance: state.cachedAppearance)

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.stowerRepository.setReadStatus = { _, isRead in
                writes.withValue { $0.append(isRead) }
            }
            $0.stowerRepository.fetchLibrary = { _ in [] }
            $0.stowerRepository.fetchListCounts = { .zero }
            $0.stowerRepository.fetchTags = { [] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reader(.presented(.doneTapped))) {
            $0.reader?.item?.isRead = true
        }
        await store.receive(
            .reader(.presented(.delegate(.done(itemID: item.id, wasUnread: true))))
        ) {
            var completed = item
            completed.isRead = true
            $0.recentlyCompletedItem = completed
            $0.reader = nil
        }

        await store.send(.undoCompletedItemTapped) {
            $0.recentlyCompletedItem = nil
        }
        #expect(writes.value == [true, false])
    }

    @Test
    func readerFocusRequiresSelectionAndToggles() async {
        let item = SavedItem(title: "Focused", content: "Body")
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(.readerFocusButtonTapped)

        await store.send(.library(.openItem(item))) {
            $0.reader = ReaderFeature.State(item: item, appearance: $0.cachedAppearance)
        }
        await store.send(.readerFocusButtonTapped) {
            $0.isReaderFocused = true
        }
        await store.send(.readerFocusButtonTapped) {
            $0.isReaderFocused = false
        }
    }

    @Test
    func readerFocusNavigatesAndExitsWhenReaderDismisses() async {
        let first = SavedItem(title: "First", content: "One")
        let second = SavedItem(title: "Second", content: "Two")
        var state = AppFeature.State()
        state.library.items = [first, second]
        state.reader = ReaderFeature.State(item: first, appearance: state.cachedAppearance)
        state.isReaderFocused = true

        let store = TestStore(initialState: state) {
            AppFeature()
        }

        #expect(!store.state.canNavigateToPreviousArticle)
        #expect(store.state.canNavigateToNextArticle)

        await store.send(.nextArticleButtonTapped) {
            $0.reader = ReaderFeature.State(item: second, appearance: $0.cachedAppearance)
        }
        #expect(store.state.canNavigateToPreviousArticle)
        #expect(!store.state.canNavigateToNextArticle)

        await store.send(.reader(.dismiss)) {
            $0.isReaderFocused = false
            $0.reader = nil
        }
    }

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
        #expect(library.contains { $0.id == created.id })

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
        let item = SavedItem(title: "One", content: "Body")
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
            $0.stowerRepository.fetchLibrary = { _ in [item] }
            $0.stowerRepository.fetchListCounts = { .zero }
            $0.stowerRepository.fetchTags = { [] }
            $0.stowerRepository.observeLibraryChanges = { AsyncStream { $0.finish() } }
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.loadSettings = { settings }
            $0.stowerRepository.loadReaderAppearanceSettings = { appearance }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.stowerRepository.claimNextIngestionJob = { _ in nil }
            $0.stowerRepository.claimNextIngestionJobOfKind = { _, _ in nil }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
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

    @Test
    func startupProcessesQueuedMarkdownJob() async throws {
        let created = LockIsolated<[IngestionResult]>([])
        let payload = try QueuedTextPayloadCodec.encode(
            QueuedTextPayload(
                content: "Just a note body",
                mode: .markdown,
                titleHint: "Meeting Notes"
            )
        )
        let queuedJobs = LockIsolated([
            IngestionJob(kind: .markdown, payload: payload),
        ])

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.cloudSyncClient = CloudSyncClient(
                start: {},
                sendChanges: {},
                scheduleSendChanges: {},
                statusStream: { AsyncStream { continuation in continuation.finish() } }
            )
            $0.stowerRepository.claimNextIngestionJob = { _ in
                queuedJobs.withValue { jobs in
                    jobs.isEmpty ? nil : jobs.removeFirst()
                }
            }
            $0.stowerRepository.claimNextIngestionJobOfKind = { _, _ in nil }
            $0.stowerRepository.createItemFromIngestion = { result in
                created.withValue { $0.append(result) }
                return SavedItem(title: result.title, content: result.plainText, renderFormat: result.renderFormat)
            }
            $0.stowerRepository.completeIngestionJob = { _, _ in }
            $0.stowerRepository.fetchLibrary = { _ in [] }
            $0.stowerRepository.fetchListCounts = { .zero }
            $0.stowerRepository.fetchTags = { [] }
            $0.stowerRepository.observeLibraryChanges = { AsyncStream { $0.finish() } }
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            $0.syncDiagnosticsClient = .noop
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(AppFeature.Action.onAppear)
        await store.receive(AppFeature.Action.startupFinished) {
            $0.startupFinished = true
        }

        let results = created.value
        #expect(results.count == 1)
        #expect(results[0].title == "Meeting Notes")
        #expect(results[0].renderFormat == .structuredV1)
    }

    @Test
    func startupProcessesLegacyRawTextJobUsingAutoDetection() async {
        let created = LockIsolated<[IngestionResult]>([])
        let markdown = """
        # Queued Heading

        - one
        - two
        """
        let queuedJobs = LockIsolated([
            IngestionJob(kind: .text, payload: markdown),
        ])

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.cloudSyncClient = CloudSyncClient(
                start: {},
                sendChanges: {},
                scheduleSendChanges: {},
                statusStream: { AsyncStream { continuation in continuation.finish() } }
            )
            $0.stowerRepository.claimNextIngestionJob = { _ in
                queuedJobs.withValue { jobs in
                    jobs.isEmpty ? nil : jobs.removeFirst()
                }
            }
            $0.stowerRepository.claimNextIngestionJobOfKind = { _, _ in nil }
            $0.stowerRepository.createItemFromIngestion = { result in
                created.withValue { $0.append(result) }
                return SavedItem(title: result.title, content: result.plainText, renderFormat: result.renderFormat)
            }
            $0.stowerRepository.completeIngestionJob = { _, _ in }
            $0.stowerRepository.fetchLibrary = { _ in [] }
            $0.stowerRepository.fetchListCounts = { .zero }
            $0.stowerRepository.fetchTags = { [] }
            $0.stowerRepository.observeLibraryChanges = { AsyncStream { $0.finish() } }
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            $0.syncDiagnosticsClient = .noop
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(AppFeature.Action.onAppear)
        await store.receive(AppFeature.Action.startupFinished) {
            $0.startupFinished = true
        }

        let results = created.value
        #expect(results.count == 1)
        #expect(results[0].title == "Queued Heading")
        #expect(results[0].renderFormat == .structuredV1)
    }

    @Test
    func failedQueuedURLDoesNotCreatePlainTextFallbackItem() async {
        let queuedJobs = LockIsolated([
            IngestionJob(kind: .url, payload: "https://example.com/article"),
        ])
        let createdItems = LockIsolated(0)
        let failures = LockIsolated<[String]>([])

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.articleSaveClient = ArticleSaveClient(
                save: { _ in throw QueuedURLCaptureError.failed },
                refresh: { _, _ in throw QueuedURLCaptureError.failed },
                hydrate: { _, _ in throw QueuedURLCaptureError.failed }
            )
            $0.cloudSyncClient = CloudSyncClient(
                start: {},
                sendChanges: {},
                scheduleSendChanges: {},
                statusStream: { AsyncStream { $0.finish() } }
            )
            $0.stowerRepository.claimNextIngestionJob = { _ in
                queuedJobs.withValue { jobs in
                    jobs.isEmpty ? nil : jobs.removeFirst()
                }
            }
            $0.stowerRepository.claimNextIngestionJobOfKind = { _, _ in nil }
            $0.stowerRepository.createItemFromIngestion = { result in
                createdItems.withValue { $0 += 1 }
                return SavedItem(title: result.title, content: result.plainText)
            }
            $0.stowerRepository.failIngestionJob = { _, message, _ in
                failures.withValue { $0.append(message) }
            }
            $0.stowerRepository.completeIngestionJob = { _, _ in }
            $0.stowerRepository.fetchLibrary = { _ in [] }
            $0.stowerRepository.fetchListCounts = { .zero }
            $0.stowerRepository.fetchTags = { [] }
            $0.stowerRepository.observeLibraryChanges = { AsyncStream { $0.finish() } }
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            $0.syncDiagnosticsClient = .noop
        }

        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.onAppear)
        await store.receive(.startupFinished) {
            $0.startupFinished = true
        }

        #expect(createdItems.value == 0)
        #expect(failures.value == ["Queued URL capture failed."])
    }
}

private enum QueuedURLCaptureError: Error, LocalizedError {
    case failed

    var errorDescription: String? { "Queued URL capture failed." }
}
