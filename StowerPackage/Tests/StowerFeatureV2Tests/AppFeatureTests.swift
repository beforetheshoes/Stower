import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite(.dependencies { try $0.bootstrapStowerDatabase(enableSync: false) })
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
    func exportCommandRoutesToLibraryForOpenArticle() async {
        let item = SavedItem(title: "Open", content: "Body", renderFormat: .structuredV1)
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: item, appearance: state.cachedAppearance)
        let exported = LockIsolated<[UUID]>([])
        let result = EPUBExportResult(itemID: item.id, fileURL: URL(fileURLWithPath: "/tmp/x.epub"), suggestedFilename: "x")

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.epubExportClient.export = { id in
                exported.withValue { $0.append(id) }
                return result
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        #expect(store.state.canExportOpenArticleAsEPUB)

        await store.send(.exportOpenArticleAsEPUB)
        await store.receive(.library(.exportEPUBTapped(item.id))) {
            $0.library.exportingItemID = item.id
        }
        #expect(!store.state.canExportOpenArticleAsEPUB)
        await store.receive(.library(.epubExportSucceeded(result))) {
            $0.library.exportingItemID = nil
            $0.library.epubExport = result
        }
        #expect(exported.value == [item.id])
    }

    @Test
    func exportCommandIsIgnoredWithoutAnExportableArticle() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        #expect(!store.state.canExportOpenArticleAsEPUB)
        await store.send(.exportOpenArticleAsEPUB)

        let website = SavedItem(title: "Site", content: "", renderFormat: .webView)
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: website, appearance: state.cachedAppearance)
        let websiteStore = TestStore(initialState: state) {
            AppFeature()
        }
        #expect(!websiteStore.state.canExportOpenArticleAsEPUB)
        await websiteStore.send(.exportOpenArticleAsEPUB)
    }

    @Test
    func readerFocusRequiresSelectionAndToggles() async {
        let item = SavedItem(title: "Focused", content: "Body")
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }

        await store.send(.readerFocusButtonTapped)

        await store.send(.library(.openItem(item))) {
            $0.library.openItemID = item.id
            $0.readerQueue = [item.id]
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
        state.readerQueue = [first.id, second.id]
        state.reader = ReaderFeature.State(item: first, appearance: state.cachedAppearance)
        state.isReaderFocused = true

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }

        #expect(!store.state.canNavigateToPreviousArticle)
        #expect(store.state.canNavigateToNextArticle)

        // The target is no longer in the observed list (for example it was
        // just marked read in Inbox), so the reader loads it by ID.
        await store.send(.nextArticleButtonTapped) {
            $0.library.openItemID = second.id
            $0.reader = ReaderFeature.State(itemID: second.id, appearance: $0.cachedAppearance)
        }
        #expect(store.state.canNavigateToPreviousArticle)
        #expect(!store.state.canNavigateToNextArticle)

        await store.send(.reader(.dismiss)) {
            $0.isReaderFocused = false
            $0.library.openItemID = nil
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
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.loadSettings = { settings }
            $0.stowerRepository.loadReaderAppearanceSettings = { appearance }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.stowerRepository.claimNextIngestionJob = { _ in nil }
            $0.stowerRepository.claimNextIngestionJobOfKind = { _, _ in nil }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            // Startup's storage tail can enqueue backfill jobs when other
            // tests have left archives in the shared container.
            $0.uuid = .incrementing
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
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            // Startup's storage tail can enqueue backfill jobs when other
            // tests have left archives in the shared container.
            $0.uuid = .incrementing
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
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            // Startup's storage tail can enqueue backfill jobs when other
            // tests have left archives in the shared container.
            $0.uuid = .incrementing
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
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            // Startup's storage tail can enqueue backfill jobs when other
            // tests have left archives in the shared container.
            $0.uuid = .incrementing
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

    @Test
    func queuedURLIsFetchedImmediatelyAndProgressIsShown() async throws {
        let url = try #require(URL(string: "https://example.com/queued"))
        let queuedJobs = LockIsolated([IngestionJob(kind: .url, payload: url.absoluteString)])
        let saved = LockIsolated<[URL]>([])

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.articleSaveClient.save = { url in
                saved.withValue { $0.append(url) }
                return ArticleSaveResult(item: SavedItem(title: "Queued", content: "Body"), state: .ready)
            }
            $0.stowerRepository.claimNextIngestionJob = { _ in
                queuedJobs.withValue { jobs in jobs.isEmpty ? nil : jobs.removeFirst() }
            }
            $0.stowerRepository.completeIngestionJob = { _, _ in }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.library(.urlQueued(url))) {
            $0.library.queuedSaveCount = 1
        }
        await store.receive(\.ingestion.saveQueued) {
            $0.ingestion.pendingSaveCount = 1
        }
        await store.receive(.ingestion(.failedImportsLoaded([])))
        await store.receive(.ingestion(.drainFinished)) {
            $0.ingestion.pendingSaveCount = 0
        }
        #expect(saved.value == [url])
    }

    @Test
    func queuedEPUBIsImportedAndItsStagedCopyRemoved() async throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let staged = scratchDir.appendingPathComponent("Novel.epub")
        try Data("epub".utf8).write(to: staged)

        let queuedJobs = LockIsolated([IngestionJob(kind: .epub, payload: staged.path)])
        let ingested = LockIsolated<[URL]>([])
        let created = LockIsolated<[String]>([])
        let completed = LockIsolated(0)
        let uploads = LockIsolated<[IngestionJob.Kind]>([])
        let book = SavedItem(title: "Novel", content: "Body")
        defer { AssetArchiver.deleteArchive(for: book.id) }

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.epubIngestionClient.ingest = { url in
                ingested.withValue { $0.append(url) }
                return .sharedText("Body")
            }
            $0.stowerRepository.createItemFromIngestion = { result in
                created.withValue { $0.append(result.plainText) }
                return book
            }
            $0.stowerRepository.enqueueIngestionJob = { kind, _ in
                uploads.withValue { $0.append(kind) }
            }
            $0.stowerRepository.claimNextIngestionJob = { _ in
                queuedJobs.withValue { jobs in jobs.isEmpty ? nil : jobs.removeFirst() }
            }
            $0.stowerRepository.completeIngestionJob = { _, _ in completed.withValue { $0 += 1 } }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.library(.urlQueued(try #require(URL(string: "https://example.com/x")))))
        await store.receive(.ingestion(.drainFinished))

        #expect(ingested.value == [staged])
        #expect(created.value.count == 1)
        #expect(completed.value == 1)
        #expect(uploads.value == [.uploadAsset])
        // The original file is kept with the item; the staged copy is gone.
        #expect(try Data(contentsOf: EPUBBookArchiver.bookURL(for: book.id)) == Data("epub".utf8))
        #expect(!FileManager.default.fileExists(atPath: scratchDir.path))
    }

    @Test
    func unreadableQueuedEPUBIsReportedAsAFailedImport() async throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let staged = scratchDir.appendingPathComponent("Locked.epub")
        try Data("epub".utf8).write(to: staged)

        let queuedJobs = LockIsolated([IngestionJob(kind: .epub, payload: staged.path)])
        let failures = LockIsolated<[String]>([])

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.epubIngestionClient.ingest = { _ in throw EPUBIngestionError.protectedContent }
            $0.stowerRepository.claimNextIngestionJob = { _ in
                queuedJobs.withValue { jobs in jobs.isEmpty ? nil : jobs.removeFirst() }
            }
            $0.stowerRepository.failIngestionJob = { _, message, _ in
                failures.withValue { $0.append(message) }
            }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.library(.urlQueued(try #require(URL(string: "https://example.com/x")))))
        await store.receive(.ingestion(.drainFinished))

        #expect(failures.value == [EPUBIngestionError.protectedContent.localizedDescription])
        #expect(!FileManager.default.fileExists(atPath: scratchDir.path))
    }

    @Test
    func syncStartFailureDoesNotBlockStartup() async {
        struct SyncError: Error, LocalizedError {
            var errorDescription: String? { "Could not determine iCloud account status" }
        }
        let settingsLoaded = LockIsolated(false)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.cloudSyncClient = CloudSyncClient(
                start: { throw SyncError() },
                sendChanges: { throw SyncError() },
                scheduleSendChanges: {},
                statusStream: { AsyncStream { $0.finish() } }
            )
            $0.stowerRepository.claimNextIngestionJob = { _ in nil }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
            $0.stowerRepository.loadSettings = {
                settingsLoaded.setValue(true)
                return ImageDownloadSettings(globalAutoDownload: true, askForNewSources: false)
            }
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            $0.uuid = .incrementing
            $0.syncDiagnosticsClient = .noop
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.sync(.statusChanged(
            CloudSyncStatus(state: .unavailable("Could not determine iCloud account status"))
        )))
        await store.receive(.startupFinished) {
            $0.startupFinished = true
            $0.startupErrorMessage = nil
        }
        await store.receive(.settings(.load))
        await store.finish()
        #expect(settingsLoaded.value)
    }

    @Test
    func unopenableDatabaseIsReportedInsteadOfShowingAnEmptyLibrary() async {
        var state = AppFeature.State()
        state.databaseUnavailableMessage = "Stower could not open its library: disk full"
        // No dependencies are stubbed: startup must not run at all.
        let store = TestStore(initialState: state) {
            AppFeature()
        }

        await store.send(.onAppear) {
            $0.startupFinished = true
            $0.startupErrorMessage = "Stower could not open its library: disk full"
        }
    }

    // MARK: - Navigation consistency

    @Test
    func deletingTheSelectedTagReturnsTheLibraryToAllItems() async {
        let tagID = UUID(7)
        var state = AppFeature.State()
        state.sidebar.selection = .tag(tagID)
        state.library.filter = .tag(tagID)

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.deleteTag = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.sidebar(.deleteTagTapped(tagID))) {
            $0.sidebar.selection = .all
        }
        await store.receive(\.library.filterChanged) {
            $0.library.filter = .all
        }
    }

    @Test
    func deletingTheOpenArticleClosesTheReader() async {
        let item = SavedItem(title: "Open", content: "Body")
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: item)
        state.library.openItemID = item.id
        state.isReaderFocused = true

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.deleteItem = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.library(.deleteItem(item.id))) {
            $0.reader = nil
            $0.isReaderFocused = false
            $0.library.openItemID = nil
        }
    }

    @Test
    func deletingAnotherArticleLeavesTheReaderOpen() async {
        let item = SavedItem(title: "Open", content: "Body")
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: item)

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.deleteItem = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.library(.deleteItem(UUID(99))))
        #expect(store.state.reader?.itemID == item.id)
    }

    @Test
    func deletingForeverWaitsForConfirmation() async {
        let id = UUID(5)
        let deleted = LockIsolated<[UUID]>([])
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.permanentlyDelete = { id in deleted.withValue { $0.append(id) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.library(.permanentlyDeleteTapped(id)))
        #expect(store.state.library.deleteConfirmation != nil)
        #expect(deleted.value.isEmpty)

        await store.send(.library(.deleteConfirmation(.presented(.confirmed(id))))) {
            $0.library.deleteConfirmation = nil
        }
        await store.receive(\.library.permanentlyDelete)
        await store.finish()
        #expect(deleted.value == [id])
    }

    @Test
    func theSelectedListIsRememberedForTheNextLaunch() async {
        let tagID = UUID(3)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        #expect(store.state.library.filter == .unread)

        await store.send(.sidebar(.selectList(.tag(tagID)))) {
            $0.sidebar.selection = .tag(tagID)
        }
        await store.receive(\.library.filterChanged)

        // A new state is what the next launch starts from.
        let relaunched = AppFeature.State()
        #expect(relaunched.sidebar.selection == .tag(tagID))
        #expect(relaunched.library.filter == .tag(tagID))
    }

    @Test
    func recentlyDeletedIsNotWhereTheNextLaunchOpens() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.sidebar(.selectList(.recentlyDeleted)))
        await store.receive(\.library.filterChanged)

        #expect(AppFeature.State().library.filter == .all)
    }

    @Test
    func listStorageKeysRoundTrip() {
        let lists: [LibraryFilter] = [.all, .unread, .read, .starred, .untagged, .tag(UUID(9))]
        for list in lists {
            #expect(LibraryFilter(storageKey: list.storageKey) == list)
        }
        #expect(LibraryFilter(storageKey: "tag:not-a-uuid") == nil)
        #expect(LibraryFilter(storageKey: "") == nil)
    }

    // MARK: - Reading position

    @Test
    func closingTheReaderWritesAPositionStillWaitingOnItsDebounce() async {
        let item = SavedItem(title: "Long read", content: "Body")
        let saved = LockIsolated<[Int]>([])
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: item)
        state.reader?.pendingProgressBlockIndex = 42

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.saveReadingProgress = { id, blockIndex in
                #expect(id == item.id)
                saved.withValue { $0.append(blockIndex) }
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reader(.dismiss)) {
            $0.reader = nil
        }
        await store.finish()
        #expect(saved.value == [42])
    }

    @Test
    func closingTheReaderWithNothingPendingWritesNothing() async {
        let saved = LockIsolated(0)
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: SavedItem(title: "Read", content: "Body"))

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.saveReadingProgress = { _, _ in saved.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reader(.dismiss)) {
            $0.reader = nil
        }
        await store.finish()
        #expect(saved.value == 0)
    }

    // MARK: - Background suspension

    /// Stubs the startup pipeline so the tests can count and gate its
    /// database steps without a real CloudKit engine.
    private func prepareStartupStubs(_ dependencies: inout DependencyValues) {
        dependencies.cloudSyncClient = CloudSyncClient(
            start: {},
            sendChanges: {},
            scheduleSendChanges: {},
            statusStream: { AsyncStream { $0.finish() } }
        )
        dependencies.stowerRepository.claimNextIngestionJob = { _ in nil }
        dependencies.stowerRepository.fetchFailedIngestionJobs = { [] }
        dependencies.stowerRepository.purgeOldTrash = { [] }
        dependencies.stowerRepository.reconcileOrphanedTagAssignments = { 0 }
        dependencies.stowerRepository.backfillTextSyncTable = { 0 }
        dependencies.stowerRepository.enqueueHydrationJobsForMissingContent = { 0 }
        dependencies.stowerRepository.loadSettings = {
            ImageDownloadSettings(globalAutoDownload: true, askForNewSources: false)
        }
        dependencies.continuousClock = ImmediateClock()
        dependencies.date.now = Date(timeIntervalSince1970: 1000)
        dependencies.uuid = .incrementing
        dependencies.syncDiagnosticsClient = .noop
    }

    @Test
    func backgroundingBeforeSyncSettlesDefersStartupMaintenanceToActivation() async {
        // The TestFlight 0xDEAD10CC: sync start was still awaiting the
        // network when the user left, and the scans began in the background.
        let (gate, release) = AsyncStream<Void>.makeStream()
        let backfills = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            prepareStartupStubs(&$0)
            $0.cloudSyncClient.start = { for await _ in gate { break } }
            $0.stowerRepository.backfillTextSyncTable = {
                backfills.withValue { $0 += 1 }
                return 0
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.send(.sceneDidEnterBackground) {
            $0.isSceneInBackground = true
            $0.startupMaintenancePending = true
        }
        release.yield()
        await store.receive(.startupSyncStarted)
        #expect(backfills.value == 0)

        await store.send(.sceneDidBecomeActive) {
            $0.isSceneInBackground = false
            $0.startupMaintenancePending = false
        }
        await store.receive(.startupFinished) {
            $0.startupFinished = true
        }
        #expect(backfills.value == 1)
    }

    @Test
    func backgroundingDuringStartupMaintenanceCancelsItAndRerunsOnActivation() async {
        let (gate, _) = AsyncStream<Void>.makeStream()
        let backfills = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            prepareStartupStubs(&$0)
            $0.stowerRepository.backfillTextSyncTable = {
                let call = backfills.withValue { $0 += 1; return $0 }
                if call == 1 {
                    // Blocks until the effect is cancelled.
                    for await _ in gate { break }
                }
                return 0
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.startupSyncStarted)
        await store.send(.sceneDidEnterBackground) {
            $0.isSceneInBackground = true
            $0.startupMaintenancePending = true
        }
        await store.send(.sceneDidBecomeActive) {
            $0.isSceneInBackground = false
            $0.startupMaintenancePending = false
        }
        await store.receive(.startupFinished) {
            $0.startupFinished = true
        }
        #expect(backfills.value == 2)
    }

    @Test
    func syncCompletingInBackgroundDefersHydrationUntilActive() async {
        let hydrations = LockIsolated(0)
        var state = AppFeature.State()
        state.isSceneInBackground = true
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            prepareStartupStubs(&$0)
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = {
                hydrations.withValue { $0 += 1 }
                return 0
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let synced = Date(timeIntervalSince1970: 2000)
        await store.send(.sync(.statusChanged(
            CloudSyncStatus(state: .available, lastSyncAttempt: synced, lastSyncSuccess: synced)
        ))) {
            $0.sync.followUpPending = true
        }
        #expect(hydrations.value == 0)

        await store.send(.sceneDidBecomeActive) {
            $0.isSceneInBackground = false
            $0.sync.followUpPending = false
            $0.sync.isFollowUpRunning = true
        }
        await store.receive(.sync(.followUpFinished)) {
            $0.sync.isFollowUpRunning = false
        }
        #expect(hydrations.value == 1)
    }

    @Test
    func startupFailureIsVisibleAndDismissible() async {
        // `startupErrorMessage` used to be set and read by nothing, so a failed
        // bootstrap presented a navigable app with a silently empty library.
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.startupFailed("App Group container unavailable.")) {
            $0.startupFinished = true
            $0.startupErrorMessage = "App Group container unavailable."
        }
        await store.send(.dismissStartupErrorTapped) {
            $0.startupErrorMessage = nil
        }
    }

    @Test
    func aSuccessfulStartupClearsAnEarlierFailure() async {
        var state = AppFeature.State()
        state.startupErrorMessage = "Previous failure."
        let store = TestStore(initialState: state) {
            AppFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.startupFinished) {
            $0.startupFinished = true
            $0.startupErrorMessage = nil
        }
    }
}

private enum QueuedURLCaptureError: Error, LocalizedError {
    case failed

    var errorDescription: String? { "Queued URL capture failed." }
}
