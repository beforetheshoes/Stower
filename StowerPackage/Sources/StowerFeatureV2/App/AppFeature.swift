import ComposableArchitecture
import Foundation
import SQLiteData

@Reducer
public struct AppFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var sidebar = SidebarFeature.State()
        public var library = LibraryFeature.State()
        public var settings = SettingsFeature.State()
        public var isReaderFocused = false
        public var isSettingsPresented: Bool = false
        /// The iPhone filter sheet (the sidebar, presented modally).
        public var isFilterSheetPresented = false
        public var cachedAppearance: ReaderAppearanceSettings
        @Presents public var reader: ReaderFeature.State?
        public var startupFinished = false
        public var startupErrorMessage: String?
        /// Set when the database could not be opened at launch. Startup is
        /// skipped — nothing it does can work — and the message is shown.
        public var databaseUnavailableMessage: String?
        /// Startup's database maintenance was cancelled, refused, or skipped
        /// because the app was in the background. The next activation runs it.
        public var startupMaintenancePending = false
        public var ingestion = IngestionFeature.State()
        public var recentlyCompletedItem: SavedItem?
        public var sync = SyncFeature.State()
        /// The ordered item IDs the reader was opened from. Next/previous
        /// walk this snapshot, so marking the open article read (which
        /// removes it from Inbox) does not strand navigation.
        public var readerQueue = [UUID]()
        /// The list that was showing when the app was last used, so a launch
        /// returns to it instead of always opening Inbox.
        @Shared(.appStorage("selectedLibraryList"))
        var storedList = LibraryFilter.unread.storageKey

        public var cloudSyncStatus: CloudSyncStatus { sync.status }
        /// True from the scene entering the background until its next
        /// activation, on platforms that suspend the process. Database
        /// maintenance is deferred while set — see `sceneDidEnterBackground`.
        /// One flag, kept by the sync feature, which defers its scans on it.
        public var isSceneInBackground: Bool {
            get { sync.isSceneInBackground }
            set { sync.isSceneInBackground = newValue }
        }
        // A computed property; the rule's pattern mistakes it for a stored array.
        // swiftlint:disable:next prefer_let_over_var
        public var failedImports: [FailedImport] { ingestion.failedImports }
        public var failedImportCount: Int { ingestion.failedImports.count }
        /// Saves queued from this app that are still being fetched.
        public var pendingSaveCount: Int { ingestion.pendingSaveCount }

        public var palette: FlexokiPalette { cachedAppearance.palette }

        public var canFocusReader: Bool { reader != nil }

        /// Drives the macOS "Export as EPUB…" command.
        public var canExportOpenArticleAsEPUB: Bool {
            (reader?.item?.isEPUBExportable ?? false) && library.exportingItemID == nil
        }

        public var canNavigateToNextArticle: Bool {
            readerNavigationTarget(offset: 1) != nil
        }

        public var canNavigateToPreviousArticle: Bool {
            readerNavigationTarget(offset: -1) != nil
        }

        func readerNavigationTarget(offset: Int) -> UUID? {
            guard
                let itemID = reader?.itemID,
                let index = readerQueue.firstIndex(of: itemID),
                readerQueue.indices.contains(index + offset)
            else { return nil }
            return readerQueue[index + offset]
        }

        public init() {
            // Seed the initial appearance from UserDefaults so the very
            // first frame is rendered in the user's chosen palette. The
            // persisted appearance still loads asynchronously from SQLite,
            // but the background + accents — which every screen depends on
            // — must be synchronously available or the entire app flashes
            // blue/white on every launch before the SQLite read completes.
            self.cachedAppearance = AppearanceCache.loadAppearance()
            // A remembered tag that has since been deleted is corrected by
            // the sidebar on its first load, and the list follows.
            if let list = LibraryFilter(storageKey: storedList) {
                sidebar.selection = list
                library.filter = list
            }
        }
    }

    /// Synchronous read/write of the last-known appearance seed so
    /// `State.init` can paint the correct background before SQLite responds.
    /// Only the three palette-driving fields are cached; everything else
    /// (font, spacing, etc.) defaults until SQLite catches up.
    enum AppearanceCache {
        static let backgroundKey = "stower.readerBackground"
        static let primaryAccentKey = "stower.readerPrimaryAccent"
        static let secondaryAccentKey = "stower.readerSecondaryAccent"
        // Legacy key from pre-Flexoki versions — fall back to it on first launch.
        static let legacyThemeKey = "stower.readerTheme"

        static func loadAppearance() -> ReaderAppearanceSettings {
            var appearance = ReaderAppearanceSettings()
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: backgroundKey) {
                appearance.background = ReaderBackground.fromStored(raw)
            } else if let legacy = defaults.string(forKey: legacyThemeKey) {
                appearance.background = ReaderBackground.fromStored(legacy)
            }
            if let raw = defaults.string(forKey: primaryAccentKey),
               let hue = FlexokiHue(rawValue: raw) {
                appearance.primaryAccent = hue
            }
            if let raw = defaults.string(forKey: secondaryAccentKey),
               let hue = FlexokiHue(rawValue: raw) {
                appearance.secondaryAccent = hue
            }
            return appearance
        }

        static func save(_ appearance: ReaderAppearanceSettings) {
            let defaults = UserDefaults.standard
            defaults.set(appearance.background.rawValue, forKey: backgroundKey)
            defaults.set(appearance.primaryAccent.rawValue, forKey: primaryAccentKey)
            defaults.set(appearance.secondaryAccent.rawValue, forKey: secondaryAccentKey)
        }
    }

    public enum Action: Equatable {
        case onAppear
        case sceneDidBecomeActive
        case browserExtensionURLReceived(URL)
        /// Another app handed Stower a file ("Open in Stower").
        case fileOpened(URL)
        case startupFinished
        case startupFailed(String)
        /// Cloud sync start has settled (started, or unavailable) and the
        /// database maintenance half of startup can begin.
        case startupSyncStarted
        /// Startup maintenance stopped because the database was suspended;
        /// it re-runs on the next activation instead of reporting an error.
        case startupMaintenanceInterrupted
        case sceneDidEnterBackground
        case dismissStartupErrorTapped
        case readerAppearanceLoaded(ReaderAppearanceSettings)
        case readerAppearanceFailed(String)
        case readerFocusButtonTapped
        case exitReaderFocus
        case nextArticleButtonTapped
        case previousArticleButtonTapped
        case toggleSelectedItemRead
        case toggleSelectedItemStarred
        case exportOpenArticleAsEPUB
        case undoCompletedItemTapped
        case completedItemNoticeExpired(UUID)
        case openSettings
        case closeSettings
        case settingsPresentationChanged(Bool)
        case filterSheetPresentationChanged(Bool)

        case ingestion(IngestionFeature.Action)
        case sync(SyncFeature.Action)
        case sidebar(SidebarFeature.Action)
        case library(LibraryFeature.Action)
        case settings(SettingsFeature.Action)
        case reader(PresentationAction<ReaderFeature.Action>)
    }

    @Dependency(\.cloudSyncClient)
    var cloudSyncClient
    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.urlIngestionClient)
    var ingestionClient
    @Dependency(\.pdfIngestionClient)
    var pdfIngestionClient
    @Dependency(\.textIngestionClient)
    var textIngestionClient
    @Dependency(\.continuousClock)
    var clock
    @Dependency(\.date)
    var date
    @Dependency(\.ingestionCoordinator)
    var ingestionCoordinator
    @Dependency(\.storageUsageClient)
    var storageUsageClient
    @Dependency(\.itemStorageClient)
    var itemStorageClient
    @Dependency(\.cloudAssetClient)
    var cloudAssetClient
    @Dependency(\.context)
    var context

    public var body: some ReducerOf<Self> {
        // Runs before the reader's own reducer and before anything replaces
        // or dismisses it. The reader debounces its progress writes by a
        // second and its effects are cancelled when it goes away, so the
        // last second of scrolling used to be lost on Done, next/previous,
        // opening another article, or popping back.
        Reduce { state, action in
            switch action {
            case .reader(.dismiss),
                 .reader(.presented(.delegate(.done))),
                 .nextArticleButtonTapped,
                 .previousArticleButtonTapped,
                 .library(.openItem):
                guard let reader = state.reader,
                      let blockIndex = reader.pendingProgressBlockIndex
                else { return .none }
                state.reader?.pendingProgressBlockIndex = nil
                let repository = self.repository
                return .run { [itemID = reader.itemID] _ in
                    await reportingErrors { try await repository.saveReadingProgress(itemID, blockIndex) }
                }
            default:
                return .none
            }
        }

        Scope(\.ingestion, action: \.ingestion) {
            IngestionFeature()
        }
        Scope(\.sync, action: \.sync) {
            SyncFeature()
        }
        Scope(\.sidebar, action: \.sidebar) {
            SidebarFeature()
        }
        Scope(\.library, action: \.library) {
            LibraryFeature()
        }
        Scope(\.settings, action: \.settings) {
            SettingsFeature()
        }
        .ifLet(\.$reader, action: \.reader) {
            ReaderFeature()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                if let message = state.databaseUnavailableMessage {
                    state.startupFinished = true
                    state.startupErrorMessage = message
                    return .none
                }
                let cloudSyncClient = self.cloudSyncClient
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                let pdfIngestionClient = self.pdfIngestionClient
                let textIngestionClient = self.textIngestionClient
                let date = self.date
                let ingestionCoordinator = self.ingestionCoordinator
                let storageUsageClient = self.storageUsageClient
                let openReaderItemID = state.reader?.itemID
                return .merge(
                    // Load appearance immediately — no dependencies, fastest possible.
                    .run { send in
                        if let appearance = try? await repository.loadReaderAppearanceSettings() {
                            await send(.readerAppearanceLoaded(appearance))
                        }
                    },
                    .send(.sync(.onAppear)),
                    // Sidebar subscription: loads counts + tags and listens for changes.
                    .send(.sidebar(.onAppear)),
                    // Purge expired trash items (fire-and-forget).
                    .run { [itemStorageClient, cloudAssetClient] _ in
                        // Snapshot trash manifests first: the purge deletes the
                        // manifest rows, and the CloudKit asset records can
                        // only be cleaned up by record name.
                        let trashedIDs = (try? await repository.fetchLibrary(.recentlyDeleted))?.map(\.id) ?? []
                        let manifestsByItem = Dictionary(
                            grouping: (try? await itemStorageClient.manifests(trashedIDs)) ?? [],
                            by: \.itemID
                        )
                        for itemID in await reportingErrors { try await repository.purgeOldTrash() } ?? [] {
                            AssetArchiver.deleteArchive(for: itemID)
                            for manifest in manifestsByItem[itemID] ?? [] {
                                try? await cloudAssetClient.delete(manifest.recordName)
                            }
                        }
                    },
                    .run { send in
                        // Sync is optional. If iCloud is unavailable the app
                        // still drains shared imports, loads settings, and
                        // runs maintenance; the sync status shows the problem.
                        //
                        // Sync start is deliberately not cancellable: the
                        // engine cannot be started twice. Everything that
                        // touches the database afterwards runs in the
                        // separately cancellable `startupSyncStarted` effect.
                        do {
                            try await cloudSyncClient.start()
                        } catch where error.isDatabaseSuspension {
                            await send(.startupMaintenanceInterrupted)
                            return
                        } catch {
                            await send(.sync(.statusChanged(
                                CloudSyncStatus(state: .unavailable(error.localizedDescription))
                            )))
                        }
                        await send(.startupSyncStarted)
                    }
                    .cancellable(id: CancelID.startup, cancelInFlight: true)
                )

            case .startupSyncStarted:
                // Backgrounded while sync was starting. Running the scans now
                // would hold locks on the App Group database right as iOS
                // suspends the process — the 0xDEAD10CC termination seen on
                // TestFlight — so wait for the next activation.
                guard !state.isSceneInBackground else {
                    state.startupMaintenancePending = true
                    return .none
                }
                state.startupMaintenancePending = false
                return startupMaintenance(state: state)

            case .startupMaintenanceInterrupted:
                // Not a failure worth reporting — showing "database is
                // suspended" would be alarming and useless. The work re-runs
                // on the next activation.
                state.startupFinished = true
                state.startupErrorMessage = nil
                state.startupMaintenancePending = true
                return .none

            case .sceneDidEnterBackground:
                // iOS kills a process with 0xDEAD10CC if it holds a lock on a
                // file in a shared container when suspended. GRDB's suspension
                // only interrupts statements running at that instant and still
                // admits WAL reads afterwards, so the long-running effects are
                // cancelled outright: GRDB interrupts a statement the moment
                // its task is cancelled, which releases the lock now. Whatever
                // was cut short runs again on activation.
                state.isSceneInBackground = true
                if !state.startupFinished {
                    state.startupMaintenancePending = true
                }
                // The children are run here, in this same pass, rather than
                // sent an action: the cancellation must not wait a turn.
                return .merge(
                    .cancel(id: CancelID.startupMaintenance),
                    SyncFeature()
                        .reduce(into: &state.sync, action: .sceneDidEnterBackground)
                        .map(Action.sync),
                    IngestionFeature()
                        .reduce(into: &state.ingestion, action: .sceneDidEnterBackground)
                        .map(Action.ingestion)
                )

            case .startupFinished:
                state.startupFinished = true
                state.startupErrorMessage = nil
                return .none

            case .startupFailed(let message):
                state.startupFinished = true
                state.startupErrorMessage = message
                return .none

            case .library(.urlQueued):
                // The link is in the ingestion queue; fetch it now rather
                // than at the next launch, and show progress meanwhile. The
                // row appears through observation as soon as the item exists.
                return .send(.ingestion(.saveQueued))

            case .dismissStartupErrorTapped:
                state.startupErrorMessage = nil
                return .none

            case .sceneDidBecomeActive:
                // The share extension enqueues ingestion jobs into the shared
                // App Group database but has no way to notify the running main
                // app. When the user returns to Stower after sharing a URL,
                // drain the queue and reload the library so newly-saved items
                // show up immediately without requiring a cold launch.
                //
                // Startup also drains the queue, so this is usually a no-op on
                // the very first activation — `processIngestionJobs` marks
                // jobs as processed and skips them on subsequent calls.
                //
                // This deliberately does NOT wait for startup to finish. When
                // the user launches Stower straight from the share sheet, the
                // activation can land while startup is still running; skipping
                // the drain then left the just-shared URL sitting in the queue
                // until some later launch. `ingestionCoordinator` serializes
                // the two drains, so overlapping is safe.
                state.isSceneInBackground = false
                var effects: [EffectOf<Self>] = [.send(.ingestion(.drainRequested))]
                // Anything the background transition cut short runs now.
                if state.startupMaintenancePending {
                    state.startupMaintenancePending = false
                    effects.append(startupMaintenance(state: state))
                }
                effects.append(
                    SyncFeature()
                        .reduce(into: &state.sync, action: .sceneDidBecomeActive)
                        .map(Action.sync)
                )
                return .merge(effects)

            case .browserExtensionURLReceived(let url):
                return .send(.library(.saveExternalURL(url)))

            case .fileOpened(let url):
                return .run { send in
                    do {
                        let file = try IncomingFile.stage(url)
                        switch file.kind {
                        case .epub:
                            await send(.library(.importEPUBSelected(file.url)))
                        case .pdf:
                            await send(.library(.importPDFSelected(file.url)))
                        }
                    } catch {
                        await send(.library(.saveURLFailed(error.localizedDescription)))
                    }
                }

            case .readerAppearanceLoaded(let appearance):
                state.cachedAppearance = appearance
                AppearanceCache.save(appearance)
                return .none

            case .readerAppearanceFailed:
                return .none

            case .readerFocusButtonTapped:
                guard state.reader != nil else {
                    state.isReaderFocused = false
                    return .none
                }
                state.isReaderFocused.toggle()
                return .none

            case .exitReaderFocus:
                state.isReaderFocused = false
                return .none

            case .nextArticleButtonTapped:
                return navigateReader(offset: 1, state: &state)

            case .previousArticleButtonTapped:
                return navigateReader(offset: -1, state: &state)

            case .toggleSelectedItemRead:
                guard let item = state.reader?.item else { return .none }
                let newValue = !item.isRead
                state.reader?.item?.isRead = newValue
                let repository = self.repository
                return .run { _ in
                    await reportingErrors { try await repository.setReadStatus(item.id, newValue) }
                }

            case .toggleSelectedItemStarred:
                guard let item = state.reader?.item else { return .none }
                let newValue = !item.isStarred
                state.reader?.item?.isStarred = newValue
                let repository = self.repository
                return .run { _ in
                    await reportingErrors { try await repository.setStarred(item.id, newValue) }
                }

            case .exportOpenArticleAsEPUB:
                guard state.canExportOpenArticleAsEPUB, let itemID = state.reader?.item?.id else {
                    return .none
                }
                return .send(.library(.exportEPUBTapped(itemID)))

            case .undoCompletedItemTapped:
                guard let item = state.recentlyCompletedItem else { return .none }
                state.recentlyCompletedItem = nil
                if state.reader?.itemID == item.id {
                    state.reader?.item?.isRead = false
                }
                let repository = self.repository
                return .run { _ in
                    await reportingErrors { try await repository.setReadStatus(item.id, false) }
                }
                .cancellable(id: CancelID.completedItemNotice, cancelInFlight: true)

            case .completedItemNoticeExpired(let itemID):
                guard state.recentlyCompletedItem?.id == itemID else { return .none }
                state.recentlyCompletedItem = nil
                return .none

            case .openSettings:
                // Settings can be opened from inside the filter sheet; that
                // sheet goes away in the same pass.
                state.isFilterSheetPresented = false
                state.isSettingsPresented = true
                return .none

            case .settingsPresentationChanged(let isPresented):
                state.isSettingsPresented = isPresented
                return .none

            case .filterSheetPresentationChanged(let isPresented):
                state.isFilterSheetPresented = isPresented
                return .none

            case .closeSettings:
                state.isSettingsPresented = false
                return .none

            case .sidebar(.selectList(let filter)):
                state.$storedList.withLock { $0 = filter.storageKey }
                // Choosing a list is what the filter sheet is for.
                state.isFilterSheetPresented = false
                return .send(.library(.filterChanged(filter)))

            case .sidebar:
                // The sidebar also moves its own selection — back to Library
                // when the selected tag is deleted here or on another
                // device. The list has to follow, or it keeps showing the
                // deleted tag's (now empty) filter under a "Library" title.
                guard state.library.filter != state.sidebar.selection else { return .none }
                state.$storedList.withLock { [list = state.sidebar.selection] in $0 = list.storageKey }
                return .send(.library(.filterChanged(state.sidebar.selection)))

            case .sync(.statusChanged(let status)):
                state.settings.cloudSyncStatus = status
                return .none

            case .sync(.delegate(.followUpScansFinished)):
                // The scans may have queued hydration jobs; the share
                // extension may have queued saves.
                return .send(.ingestion(.drainRequested))

            case .sync(.delegate(.resetFailed(let message))):
                return .send(.startupFailed(message))

            case .library(.openItem(let item)):
                // Re-tapping the same row must NOT rebuild `state.reader` —
                // a fresh `ReaderFeature.State` wipes `document`/`sourceHTML`
                // back to nil, and `ReaderScreen`'s `.task(id: store.itemID)`
                // only re-fires when the item ID *changes*, so `.load` would
                // never run again and the view would fall through its
                // else-if chain to "Item not found". Leaving the existing
                // state in place keeps the already-loaded document visible.
                state.library.openItemID = item.id
                if state.reader?.itemID == item.id {
                    return .none
                }
                state.readerQueue = state.library.items.map(\.id)
                if !state.readerQueue.contains(item.id) {
                    state.readerQueue = [item.id]
                }
                state.reader = ReaderFeature.State(
                    item: item,
                    appearance: state.cachedAppearance
                )
                // Recency stamp drives least-recently-opened eviction order.
                let itemStorageClient = self.itemStorageClient
                return .run { _ in
                    try? await itemStorageClient.touchOpened(item.id)
                }

            case .reader(.presented(.backgroundChanged(let bg))):
                state.cachedAppearance.background = bg
                AppearanceCache.save(state.cachedAppearance)
                return .none

            case .reader(.presented(.primaryAccentChanged(let hue))):
                state.cachedAppearance.primaryAccent = hue
                AppearanceCache.save(state.cachedAppearance)
                return .none

            case .reader(.presented(.secondaryAccentChanged(let hue))):
                state.cachedAppearance.secondaryAccent = hue
                AppearanceCache.save(state.cachedAppearance)
                return .none

            case .reader(.presented(.saveAppearanceFinished)):
                // Keep cached appearance in sync when reader saves changes
                if let readerAppearance = state.reader?.appearance {
                    state.cachedAppearance = readerAppearance
                    AppearanceCache.save(readerAppearance)
                }
                return .none

            case let .reader(.presented(.delegate(.done(itemID, wasUnread)))):
                if wasUnread, let item = state.reader?.item {
                    state.recentlyCompletedItem = item
                }
                state.reader = nil
                state.isReaderFocused = false
                state.library.openItemID = nil

                let clock = self.clock
                let expiration: EffectOf<Self> = wasUnread
                    ? .run { send in
                        try? await clock.sleep(for: .seconds(6))
                        await send(.completedItemNoticeExpired(itemID))
                    }
                    .cancellable(id: CancelID.completedItemNotice, cancelInFlight: true)
                    : .none

                return expiration

            case let .reader(.presented(.delegate(.finishedReading(itemID)))):
                guard let item = state.reader?.item, item.id == itemID else { return .none }
                state.recentlyCompletedItem = item
                let clock = self.clock
                return .run { send in
                    try? await clock.sleep(for: .seconds(6))
                    await send(.completedItemNoticeExpired(itemID))
                }
                .cancellable(id: CancelID.completedItemNotice, cancelInFlight: true)

            case .reader(.dismiss):
                state.isReaderFocused = false
                state.library.openItemID = nil
                return .none

            case .library(.deleteItem(let id)), .library(.permanentlyDelete(let id)):
                // Deleting the open article closes it; the reader used to
                // keep showing an item that was no longer in the list.
                guard state.reader?.itemID == id else { return .none }
                state.reader = nil
                state.isReaderFocused = false
                state.library.openItemID = nil
                return .none

            case .library, .settings, .reader, .ingestion, .sync:
                return .none
            }
        }
    }

    enum CancelID {
        case startup
        case startupMaintenance
        case completedItemNotice
    }
}
