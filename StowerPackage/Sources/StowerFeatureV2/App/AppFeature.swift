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
        public var cachedAppearance: ReaderAppearanceSettings
        @Presents public var reader: ReaderFeature.State?
        public var startupFinished = false
        public var startupErrorMessage: String?
        public var failedImportCount = 0
        public var recentlyCompletedItem: SavedItem?
        public var cloudSyncStatus: CloudSyncStatus = .starting
        @Presents public var resetAlert: AlertState<Action.ResetAlert>?

        public var palette: FlexokiPalette { cachedAppearance.palette }

        public var canFocusReader: Bool { reader != nil }

        public var canNavigateToNextArticle: Bool {
            guard
                let itemID = reader?.itemID,
                let index = library.filteredItems.firstIndex(where: { $0.id == itemID })
            else { return false }
            return library.filteredItems.indices.contains(index + 1)
        }

        public var canNavigateToPreviousArticle: Bool {
            guard
                let itemID = reader?.itemID,
                let index = library.filteredItems.firstIndex(where: { $0.id == itemID })
            else { return false }
            return library.filteredItems.indices.contains(index - 1)
        }

        public init() {
            // Seed the initial appearance from UserDefaults so the very
            // first frame is rendered in the user's chosen palette. The
            // persisted appearance still loads asynchronously from SQLite,
            // but the background + accents — which every screen depends on
            // — must be synchronously available or the entire app flashes
            // blue/white on every launch before the SQLite read completes.
            self.cachedAppearance = AppearanceCache.loadAppearance()
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
        case startupFinished
        case startupFailed(String)
        case failedImportsLoaded(Int)
        case retryFailedImportsTapped
        case dismissFailedImportsTapped
        case readerAppearanceLoaded(ReaderAppearanceSettings)
        case readerAppearanceFailed(String)
        case readerFocusButtonTapped
        case exitReaderFocus
        case nextArticleButtonTapped
        case previousArticleButtonTapped
        case toggleSelectedItemRead
        case toggleSelectedItemStarred
        case undoCompletedItemTapped
        case completedItemNoticeExpired(UUID)
        case openSettings
        case closeSettings
        case cloudSyncStatusChanged(CloudSyncStatus)
        case resetAlert(PresentationAction<ResetAlert>)

        case sidebar(SidebarFeature.Action)
        case library(LibraryFeature.Action)
        case settings(SettingsFeature.Action)
        case reader(PresentationAction<ReaderFeature.Action>)

        public enum ResetAlert: Equatable {
            case confirmReset
            case cancel
        }
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
    @Dependency(\.defaultDatabase)
    var database
    @Dependency(\.defaultSyncEngine)
    var syncEngine
    @Dependency(\.continuousClock)
    var clock
    @Dependency(\.date)
    var date
    @Dependency(\.ingestionCoordinator)
    var ingestionCoordinator
    @Dependency(\.context)
    var context

    public var body: some ReducerOf<Self> {
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
                let cloudSyncClient = self.cloudSyncClient
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                let pdfIngestionClient = self.pdfIngestionClient
                let textIngestionClient = self.textIngestionClient
                let date = self.date
                let ingestionCoordinator = self.ingestionCoordinator
                let clock = self.clock
                let periodicSync: EffectOf<Self> =
                    context == .live
                    ? .run { _ in
                        // CloudKit push delivery is not guaranteed (especially on macOS). While the app is
                        // running, periodically force a sync to pull remote changes.
                        while !Task.isCancelled {
                            do {
                                try await clock.sleep(for: .seconds(120))
                            } catch {
                                return
                            }
                            try? await cloudSyncClient.sendChanges()
                        }
                    }
                    .cancellable(id: CancelID.periodicSync, cancelInFlight: true)
                    : .none

                return .merge(
                    // Load appearance immediately — no dependencies, fastest possible.
                    .run { send in
                        if let appearance = try? await repository.loadReaderAppearanceSettings() {
                            await send(.readerAppearanceLoaded(appearance))
                        }
                    },
                    .run { send in
                        for await status in cloudSyncClient.statusStream() {
                            await send(.cloudSyncStatusChanged(status))
                        }
                    }
                    .cancellable(id: CancelID.syncStatus, cancelInFlight: true),
                    periodicSync,
                    // Sidebar subscription: loads counts + tags and listens for changes.
                    .send(.sidebar(.onAppear)),
                    // Purge expired trash items (fire-and-forget).
                    .run { _ in
                        for itemID in (try? await repository.purgeOldTrash()) ?? [] {
                            AssetArchiver.deleteArchive(for: itemID)
                        }
                    },
                    .run { send in
                        do {
                            try await cloudSyncClient.start()
                            _ = try await repository.reconcileOrphanedTagAssignments()
                            // Backfill the text sync table from local content
                            // for any text items missing a sync row (recovery
                            // from the v11 DROP TABLE migration or items that
                            // predate the sync table).
                            _ = try await repository.backfillTextSyncTable()
                            _ = try await repository.enqueueHydrationJobsForMissingContent()
                            try await ingestionCoordinator.run {
                                try await processIngestionJobs(
                                    repository: repository,
                                    ingestionClient: ingestionClient,
                                    pdfIngestionClient: pdfIngestionClient,
                                    textIngestionClient: textIngestionClient
                                ) { date.now }
                            }
                            await send(.failedImportsLoaded(
                                try await repository.fetchFailedIngestionJobs().count
                            ))
                            try await cloudSyncClient.sendChanges()
                            await send(.startupFinished)
                            await send(.library(.reload))
                            await send(.settings(.load))
                        } catch {
                            await send(.startupFailed(error.localizedDescription))
                        }
                    }
                    .cancellable(id: CancelID.startup, cancelInFlight: true)
                )

            case .startupFinished:
                state.startupFinished = true
                state.startupErrorMessage = nil
                return .none

            case .startupFailed(let message):
                state.startupFinished = true
                state.startupErrorMessage = message
                return .none

            case .failedImportsLoaded(let count):
                state.failedImportCount = count
                return .none

            case .retryFailedImportsTapped:
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                let pdfIngestionClient = self.pdfIngestionClient
                let textIngestionClient = self.textIngestionClient
                let date = self.date
                let ingestionCoordinator = self.ingestionCoordinator
                state.failedImportCount = 0
                return .run { send in
                    try? await repository.retryFailedIngestionJobs()
                    try? await ingestionCoordinator.run {
                        try await processIngestionJobs(
                            repository: repository,
                            ingestionClient: ingestionClient,
                            pdfIngestionClient: pdfIngestionClient,
                            textIngestionClient: textIngestionClient
                        ) { date.now }
                    }
                    let count = (try? await repository.fetchFailedIngestionJobs().count) ?? 0
                    await send(.failedImportsLoaded(count))
                    await send(.library(.reload))
                }

            case .dismissFailedImportsTapped:
                let repository = self.repository
                let now = date.now
                state.failedImportCount = 0
                return .run { _ in
                    try? await repository.dismissFailedIngestionJobs(now)
                }

            case .sceneDidBecomeActive:
                // The share extension enqueues ingestion jobs into the shared
                // App Group database but has no way to notify the running main
                // app. When the user returns to Stower after sharing a URL,
                // drain the queue and reload the library so newly-saved items
                // show up immediately without requiring a cold launch.
                //
                // Startup already drains the queue once, so this is a no-op on
                // the very first activation — `processIngestionJobs` marks
                // jobs as processed and skips them on subsequent calls.
                guard state.startupFinished else { return .none }
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                let pdfIngestionClient = self.pdfIngestionClient
                let textIngestionClient = self.textIngestionClient
                let date = self.date
                let ingestionCoordinator = self.ingestionCoordinator
                return .run { send in
                    try? await ingestionCoordinator.run {
                        try await processIngestionJobs(
                            repository: repository,
                            ingestionClient: ingestionClient,
                            pdfIngestionClient: pdfIngestionClient,
                            textIngestionClient: textIngestionClient
                        ) { date.now }
                    }
                    let count = (try? await repository.fetchFailedIngestionJobs().count) ?? 0
                    await send(.failedImportsLoaded(count))
                    await send(.library(.reload))
                    await send(.sidebar(.reload))
                }

            case .browserExtensionURLReceived(let url):
                return .send(.library(.saveExternalURL(url)))

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
                guard let itemID = state.reader?.itemID else { return .none }
                state.reader?.item?.isRead.toggle()
                return .send(.library(.toggleRead(itemID)))

            case .toggleSelectedItemStarred:
                guard let itemID = state.reader?.itemID else { return .none }
                state.reader?.item?.isStarred.toggle()
                return .send(.library(.toggleStar(itemID)))

            case .undoCompletedItemTapped:
                guard let item = state.recentlyCompletedItem else { return .none }
                state.recentlyCompletedItem = nil
                let repository = self.repository
                return .run { send in
                    try? await repository.setReadStatus(item.id, false)
                    await send(.library(.reload))
                    await send(.sidebar(.reload))
                }
                .cancellable(id: CancelID.completedItemNotice, cancelInFlight: true)

            case .completedItemNoticeExpired(let itemID):
                guard state.recentlyCompletedItem?.id == itemID else { return .none }
                state.recentlyCompletedItem = nil
                return .none

            case .openSettings:
                state.isSettingsPresented = true
                return .none

            case .closeSettings:
                state.isSettingsPresented = false
                return .none

            case .sidebar(.selectList(let filter)):
                return .send(.library(.filterChanged(filter)))

            case .sidebar:
                return .none

            case .cloudSyncStatusChanged(let status):
                let previous = state.cloudSyncStatus
                state.cloudSyncStatus = status
                state.settings.cloudSyncStatus = status

                // If we just completed a sync, refresh the library and kick hydration for newly-arrived records.
                if status.lastSyncSuccess != nil, status.lastSyncSuccess != previous.lastSyncSuccess {
                    let repository = self.repository
                    let ingestionClient = self.ingestionClient
                    let pdfIngestionClient = self.pdfIngestionClient
                    let textIngestionClient = self.textIngestionClient
                    let date = self.date
                    let ingestionCoordinator = self.ingestionCoordinator
                    return .run { send in
                        _ = try? await repository.enqueueHydrationJobsForMissingContent()
                        _ = try? await repository.hydratePDFItemsFromSyncedContent()
                        _ = try? await repository.hydrateTextItemsFromSyncedContent()
                        _ = try? await repository.hydrateWebsiteItemsFromSyncedContent()
                        _ = try? await repository.reconcileOrphanedTagAssignments()
                        try? await ingestionCoordinator.run {
                            try await processIngestionJobs(
                                repository: repository,
                                ingestionClient: ingestionClient,
                                pdfIngestionClient: pdfIngestionClient,
                                textIngestionClient: textIngestionClient
                            ) { date.now }
                        }
                        let count = (try? await repository.fetchFailedIngestionJobs().count) ?? 0
                        await send(.failedImportsLoaded(count))
                        await send(.library(.reload))
                        await send(.sidebar(.reload))
                    }
                }

                switch status.state {
                case .needsLocalReset(let reason):
                    state.resetAlert = AlertState {
                        TextState("Reset local data?")
                    } actions: {
                        ButtonState(role: .destructive, action: .confirmReset) {
                            TextState("Reset")
                        }
                        ButtonState(role: .cancel, action: .cancel) {
                            TextState("Cancel")
                        }
                    } message: {
                        TextState("\(reason). This clears local data and does not delete iCloud data.")
                    }
                default:
                    break
                }
                return .none

            case .resetAlert(.presented(.confirmReset)):
                let database = self.database
                let syncEngine = self.syncEngine
                return .run { _ in
                    // Clear local CloudKit state for synced tables (does not delete iCloud data).
                    try? await syncEngine.deleteLocalData()
                    // Clear local-only tables.
                    try await database.write { db in
                        try db.execute(sql: #"DELETE FROM "savedItemContentLocalTables""#)
                        try db.execute(sql: #"DELETE FROM "savedMediaLocalTables""#)
                        try db.execute(sql: #"DELETE FROM "savedEmbedLocalTables""#)
                        try db.execute(sql: #"DELETE FROM "savedImageRefLocalTables""#)
                        try db.execute(sql: #"DELETE FROM "savedImageAssetLocalTables""#)
                        try db.execute(sql: #"DELETE FROM "ingestionJobLocalTables""#)
                        try db.execute(sql: #"DELETE FROM "imageDownloadSettingsLocalTables""#)
                        try db.execute(sql: #"DELETE FROM "readerAppearanceSettingsLocalTables""#)
                    }
                }

            case .resetAlert(.presented(.cancel)), .resetAlert(.dismiss):
                return .none

            case .library(.openItem(let item)):
                // Re-tapping the same row must NOT rebuild `state.reader` —
                // a fresh `ReaderFeature.State` wipes `document`/`sourceHTML`
                // back to nil, and `ReaderScreen`'s `.task(id: store.itemID)`
                // only re-fires when the item ID *changes*, so `.load` would
                // never run again and the view would fall through its
                // else-if chain to "Item not found". Leaving the existing
                // state in place keeps the already-loaded document visible.
                if state.reader?.itemID == item.id {
                    return .none
                }
                state.reader = ReaderFeature.State(
                    item: item,
                    appearance: state.cachedAppearance
                )
                return .none

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

                let clock = self.clock
                let expiration: EffectOf<Self> = wasUnread
                    ? .run { send in
                        try? await clock.sleep(for: .seconds(6))
                        await send(.completedItemNoticeExpired(itemID))
                    }
                    .cancellable(id: CancelID.completedItemNotice, cancelInFlight: true)
                    : .none

                return .merge(
                    .send(.library(.reload)),
                    .send(.sidebar(.reload)),
                    expiration
                )

            case .reader(.dismiss):
                state.isReaderFocused = false
                return .none

            case .library, .settings, .reader:
                return .none
            }
        }
    }

    enum CancelID {
        case startup
        case syncStatus
        case periodicSync
        case completedItemNotice
    }

    private func navigateReader(
        offset: Int,
        state: inout State
    ) -> EffectOf<Self> {
        guard
            let itemID = state.reader?.itemID,
            let index = state.library.filteredItems.firstIndex(where: { $0.id == itemID }),
            state.library.filteredItems.indices.contains(index + offset)
        else { return .none }

        state.reader = ReaderFeature.State(
            item: state.library.filteredItems[index + offset],
            appearance: state.cachedAppearance
        )
        return .none
    }
}

private func processIngestionJobs(
    repository: StowerRepository,
    ingestionClient: URLIngestionClient,
    pdfIngestionClient: PDFIngestionClient,
    textIngestionClient: TextIngestionClient,
    now: @escaping @Sendable () -> Date
) async throws {
    while let job = try await repository.claimNextIngestionJob(now()) {
        do {
            try await processIngestionJob(
                job,
                repository: repository,
                ingestionClient: ingestionClient,
                pdfIngestionClient: pdfIngestionClient,
                textIngestionClient: textIngestionClient
            )
            try await repository.completeIngestionJob(job.id, now())
        } catch is CancellationError {
            try? await repository.failIngestionJob(job.id, "Import cancelled.", now())
            throw CancellationError()
        } catch {
            try await repository.failIngestionJob(job.id, error.localizedDescription, now())
        }
    }
}

private func processIngestionJob(
    _ job: IngestionJob,
    repository: StowerRepository,
    ingestionClient: URLIngestionClient,
    pdfIngestionClient: PDFIngestionClient,
    textIngestionClient: TextIngestionClient
) async throws {
    @Dependency(\.articleSaveClient)
    var articleSaveClient
    switch job.kind {
        case .url:
            let trimmed = job.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw IngestionProcessingError.invalidHydrationURL(trimmed)
            }
            _ = try await articleSaveClient.save(url)
        case .pdf:
            // Payload is the absolute path of a PDF file that the share
            // extension or in-app picker copied into the shared App Group
            // container. The file lives inside a UUID-named subdirectory
            // (so the original filename is preserved for title fallback);
            // clean up the whole subdir once ingestion is done.
            let pdfURL = URL(fileURLWithPath: job.payload)
            let scratchDir = pdfURL.deletingLastPathComponent()
            do {
                let result = try await pdfIngestionClient.ingest(pdfURL)
                let item = try await repository.createItemFromIngestion(result)
                try? PDFArchiver.archivePDF(from: pdfURL, itemID: item.id)
                try? FileManager.default.removeItem(at: scratchDir)
            } catch {
                let fallback = pdfURL.deletingPathExtension().lastPathComponent
                _ = try? await repository.createItemFromIngestion(
                    .sharedText("Failed to ingest PDF: \(fallback)\n\n\(error.localizedDescription)")
                )
                try? FileManager.default.removeItem(at: scratchDir)
            }
        case .text:
            let payload = QueuedTextPayloadCodec.decode(job.payload, defaultMode: .auto)
            let result = try await textIngestionClient.ingest(
                payload.content,
                nil,
                payload.titleHint,
                payload.mode
            )
            _ = try await repository.createItemFromIngestion(result)
        case .markdown:
            let payload = QueuedTextPayloadCodec.decode(job.payload, defaultMode: .markdown)
            let result = try await textIngestionClient.ingest(
                payload.content,
                nil,
                payload.titleHint,
                .markdown
            )
            _ = try await repository.createItemFromIngestion(result)
        case .hydrateText:
            let data = Data(job.payload.utf8)
            let payload = try JSONDecoder().decode(TextHydrationPayload.self, from: data)
            do {
                let mode = payload.rawSourceMode
                    .flatMap(TextImportMode.init(rawValue:))
                    ?? .auto
                let result = try await textIngestionClient.ingest(
                    payload.rawSourceText,
                    payload.title,
                    nil,
                    mode
                )
                try await repository.hydrateItemContent(payload.itemID, result)
            } catch {
                try? await repository.updateLocalContentStatus(payload.itemID, "failed", error.localizedDescription)
                throw error
            }
        case .hydrate:
            let data = Data(job.payload.utf8)
            let payload = try JSONDecoder().decode(HydrationPayload.self, from: data)
            if let url = URL(string: payload.url) {
                do {
                    try await repository.updateLocalContentStatus(payload.itemID, "downloading", nil)
                    _ = try await articleSaveClient.hydrate(payload.itemID, url)
                } catch {
                    try? await repository.updateLocalContentStatus(payload.itemID, "failed", error.localizedDescription)
                    throw error
                }
            } else {
                throw IngestionProcessingError.invalidHydrationURL(payload.url)
            }
        case .website:
            // Payload is the absolute path of a .zip file the share extension
            // (or another background enqueuer) copied into the shared App
            // Group container (PendingWebsites/{uuid}/). The in-app picker
            // path imports inline via WebsiteImportService without touching
            // this queue.
            let zipURL = URL(fileURLWithPath: job.payload)
            let scratchDir = zipURL.deletingLastPathComponent()
            do {
                _ = try await WebsiteImportService.importWebsite(
                    zipURL: zipURL,
                    repository: repository
                )
                try? FileManager.default.removeItem(at: scratchDir)
            } catch {
                let fallback = zipURL.deletingPathExtension().lastPathComponent
                _ = try? await repository.createItemFromIngestion(
                    .sharedText("Failed to import website: \(fallback)\n\n\(error.localizedDescription)")
                )
                try? FileManager.default.removeItem(at: scratchDir)
            }
        case .hydrateWebsite:
            // Receive-side: the website archive arrived via CloudKit sync but
            // the site isn't unpacked locally yet. Pull the zip bytes out of
            // the sync table and run the same unpack logic we use on the
            // originating device.
            let data = Data(job.payload.utf8)
            let payload = try JSONDecoder().decode(WebsiteHydrationPayload.self, from: data)
            do {
                guard let archive = try await repository.loadWebsiteArchive(payload.itemID) else {
                    throw IngestionProcessingError.missingWebsiteArchive
                }
                try await WebsiteImportService.hydrateWebsite(
                    itemID: payload.itemID,
                    archive: archive,
                    repository: repository
                )
            } catch {
                try? await repository.updateLocalContentStatus(
                    payload.itemID,
                    "failed",
                    error.localizedDescription
                )
                throw error
            }
        }
}

private enum IngestionProcessingError: LocalizedError {
    case invalidHydrationURL(String)
    case missingWebsiteArchive

    var errorDescription: String? {
        switch self {
        case .invalidHydrationURL(let value):
            "Invalid hydration URL: \(value)"
        case .missingWebsiteArchive:
            "The synced website archive is not available yet."
        }
    }
}
