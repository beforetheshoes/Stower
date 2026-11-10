import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct IngestionFeatureTests {
    @Test
    func aQueuedSaveShowsProgressUntilTheDrainFinishes() async {
        let store = TestStore(initialState: IngestionFeature.State()) {
            IngestionFeature()
        } withDependencies: {
            $0.stowerRepository.claimNextIngestionJob = { _ in nil }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }

        await store.send(.saveQueued) {
            $0.pendingSaveCount = 1
            $0.activeDrainCount = 1
        }
        await store.receive(.failedImportsLoaded([]))
        await store.receive(.drainFinished) {
            $0.activeDrainCount = 0
            $0.pendingSaveCount = 0
        }
    }

    @Test
    func retryClearsTheListAndRequeuesBeforeDraining() async {
        let retried = LockIsolated(0)
        var state = IngestionFeature.State()
        state.failedImports = [FailedImport(id: UUID(1), label: "Broken", reason: "Timed out")]
        let store = TestStore(initialState: state) {
            IngestionFeature()
        } withDependencies: {
            $0.stowerRepository.retryFailedIngestionJobs = { retried.withValue { $0 += 1 } }
            $0.stowerRepository.claimNextIngestionJob = { _ in nil }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.retryFailedImportsTapped) {
            $0.failedImports = []
        }
        await store.receive(.drainFinished)
        #expect(retried.value == 1)
    }

    @Test
    func dismissingClearsTheListAndRecordsIt() async {
        let dismissed = LockIsolated(0)
        var state = IngestionFeature.State()
        state.failedImports = [FailedImport(id: UUID(1), label: "Broken", reason: "Timed out")]
        let store = TestStore(initialState: state) {
            IngestionFeature()
        } withDependencies: {
            $0.stowerRepository.dismissFailedIngestionJobs = { _ in dismissed.withValue { $0 += 1 } }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }

        await store.send(.dismissFailedImportsTapped) {
            $0.failedImports = []
        }
        await store.finish()
        #expect(dismissed.value == 1)
    }

    @Test
    func backgroundingKeepsTheSavingNoticeForTheReturn() async {
        var state = IngestionFeature.State()
        state.pendingSaveCount = 2
        state.activeDrainCount = 1
        let store = TestStore(initialState: state) {
            IngestionFeature()
        }

        await store.send(.sceneDidEnterBackground) {
            $0.activeDrainCount = 0
        }
        #expect(store.state.pendingSaveCount == 2)
    }
}

@MainActor
@Suite
struct SyncFeatureTests {
    private let synced = Date(timeIntervalSince1970: 2000)

    private func makeStore(
        _ state: SyncFeature.State = .init(),
        scans: LockIsolated<Int> = LockIsolated(0)
    ) -> TestStoreOf<SyncFeature> {
        TestStore(initialState: state) {
            SyncFeature()
        } withDependencies: {
            $0.stowerRepository.enqueueHydrationJobsForMissingContent = {
                scans.withValue { $0 += 1 }
                return 0
            }
        }
    }

    @Test
    func aCompletedSyncRunsTheFollowUpAndAsksForADrain() async {
        let scans = LockIsolated(0)
        let store = makeStore(scans: scans)
        let status = CloudSyncStatus(state: .available, lastSyncAttempt: synced, lastSyncSuccess: synced)

        await store.send(.statusChanged(status)) {
            $0.status = status
            $0.isFollowUpRunning = true
        }
        await store.receive(.delegate(.followUpScansFinished))
        await store.receive(.followUpFinished) {
            $0.isFollowUpRunning = false
        }
        #expect(scans.value == 1)
    }

    @Test
    func theSameSyncReportedTwiceRunsTheFollowUpOnce() async {
        let scans = LockIsolated(0)
        let store = makeStore(scans: scans)
        store.exhaustivity = .off(showSkippedAssertions: false)
        let status = CloudSyncStatus(state: .available, lastSyncAttempt: synced, lastSyncSuccess: synced)

        await store.send(.statusChanged(status))
        await store.receive(.followUpFinished)
        await store.send(.statusChanged(status))
        await store.finish()

        #expect(scans.value == 1)
    }

    @Test
    func aSyncThatCompletesInTheBackgroundWaitsForTheForeground() async {
        let scans = LockIsolated(0)
        var state = SyncFeature.State()
        state.isSceneInBackground = true
        let store = makeStore(state, scans: scans)
        let status = CloudSyncStatus(state: .available, lastSyncAttempt: synced, lastSyncSuccess: synced)

        await store.send(.statusChanged(status)) {
            $0.status = status
            $0.followUpPending = true
        }
        #expect(scans.value == 0)

        await store.send(.sceneDidBecomeActive) {
            $0.isSceneInBackground = false
            $0.followUpPending = false
            $0.isFollowUpRunning = true
        }
        await store.receive(.delegate(.followUpScansFinished))
        await store.receive(.followUpFinished) {
            $0.isFollowUpRunning = false
        }
        #expect(scans.value == 1)
    }

    @Test
    func backgroundingARunningFollowUpMarksItPending() async {
        var state = SyncFeature.State()
        state.isFollowUpRunning = true
        let store = makeStore(state)

        await store.send(.sceneDidEnterBackground) {
            $0.isSceneInBackground = true
            $0.isFollowUpRunning = false
            $0.followUpPending = true
        }
    }

    @Test
    func aResetRequestFromTheEngineAsksFirst() async {
        let store = makeStore()
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.statusChanged(CloudSyncStatus(state: .needsLocalReset("Zone was deleted"))))
        #expect(store.state.resetAlert != nil)

        await store.send(.resetAlert(.presented(.cancel)))
        #expect(store.state.resetAlert == nil)
    }
}

@MainActor
@Suite(.dependencies { try $0.bootstrapStowerDatabase(enableSync: false) })
struct AppPresentationTests {
    private func makeStore(_ state: AppFeature.State = .init()) -> TestStoreOf<AppFeature> {
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.claimNextIngestionJob = { _ in nil }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test
    func choosingAListClosesTheFilterSheet() async {
        var state = AppFeature.State()
        state.isFilterSheetPresented = true
        let store = makeStore(state)

        await store.send(.sidebar(.selectList(.starred))) {
            $0.isFilterSheetPresented = false
        }
        await store.receive(\.library.filterChanged)
    }

    @Test
    func openingSettingsFromTheFilterSheetReplacesIt() async {
        var state = AppFeature.State()
        state.isFilterSheetPresented = true
        let store = makeStore(state)

        await store.send(.openSettings) {
            $0.isFilterSheetPresented = false
            $0.isSettingsPresented = true
        }
        await store.send(.settingsPresentationChanged(false)) {
            $0.isSettingsPresented = false
        }
    }

    @Test
    func aSyncFollowUpDrainsTheQueue() async {
        let store = makeStore()

        await store.send(.sync(.delegate(.followUpScansFinished)))
        await store.receive(\.ingestion.drainRequested)
    }

    @Test
    func aFailedResetIsShown() async {
        let store = makeStore()

        await store.send(.sync(.delegate(.resetFailed("Reset did not finish: offline"))))
        await store.receive(.startupFailed("Reset did not finish: offline")) {
            $0.startupErrorMessage = "Reset did not finish: offline"
        }
    }
}

@MainActor
@Suite(.dependencies { try $0.bootstrapStowerDatabase(enableSync: false) })
struct LastArticleTests {
    private let item = SavedItem(title: "Long read", content: "Body")

    private func makeStore(
        _ state: AppFeature.State = .init(),
        loadItem: @escaping @Sendable (UUID) async throws -> SavedItem? = { _ in nil }
    ) -> TestStoreOf<AppFeature> {
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository.loadItem = loadItem
            $0.stowerRepository.claimNextIngestionJob = { _ in nil }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.stowerRepository.purgeOldTrash = { [] }
            $0.cloudSyncClient = .noop
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
            $0.uuid = .incrementing
            $0.syncDiagnosticsClient = .noop
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test
    func theOpenArticleIsRememberedAndForgottenWhenClosed() async {
        let store = makeStore()

        await store.send(.library(.openItem(item)))
        #expect(store.state.lastOpenItemID == item.id.uuidString)

        await store.send(.reader(.dismiss))
        #expect(store.state.lastOpenItemID.isEmpty)
    }

    @Test
    func aLaunchReopensTheArticleThatWasOpen() async {
        var state = AppFeature.State()
        state.$lastOpenItemID.withLock { $0 = item.id.uuidString }
        let item = self.item
        let store = makeStore(state) { id in id == item.id ? item : nil }

        await store.send(.onAppear)
        await store.receive(.lastArticleRestored(item)) {
            $0.reader = ReaderFeature.State(item: item, appearance: $0.cachedAppearance)
            $0.library.openItemID = item.id
        }
        await store.skipInFlightEffects()
    }

    @Test
    func anArticleDeletedSinceIsNotReopened() async {
        var trashed = item
        trashed.deletedAt = Date(timeIntervalSince1970: 500)
        var state = AppFeature.State()
        state.$lastOpenItemID.withLock { $0 = trashed.id.uuidString }
        let store = makeStore(state) { [trashed] _ in trashed }

        await store.send(.onAppear)
        await store.receive(\.startupFinished)
        #expect(store.state.reader == nil)
        await store.skipInFlightEffects()
    }

    @Test
    func restoringDoesNotReplaceAnArticleOpenedInTheMeantime() async {
        let other = SavedItem(title: "Opened first", content: "Body")
        var state = AppFeature.State()
        state.reader = ReaderFeature.State(item: other)
        let store = makeStore(state)

        await store.send(.lastArticleRestored(item))
        #expect(store.state.reader?.itemID == other.id)
    }
}
