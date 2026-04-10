import ComposableArchitecture
import Foundation

@Reducer
public struct AppFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var sidebar = SidebarFeature.State()
        public var library = LibraryFeature.State()
        public var settings = SettingsFeature.State()
        public var isSettingsPresented: Bool = false
        public var readerTheme: ReaderTheme
        public var cachedAppearance: ReaderAppearanceSettings
        @Presents public var reader: ReaderFeature.State?
        public var startupFinished = false
        public var startupErrorMessage: String?
        public var cloudSyncStatus: CloudSyncStatus = .starting
        @Presents public var resetAlert: AlertState<Action.ResetAlert>?

        public init() {
            // Seed the initial theme from UserDefaults so the very first
            // frame is rendered in the right color. Persisted appearance
            // still loads asynchronously from SQLite, but the theme —
            // which is what every background on the screen depends on —
            // must be synchronously available or the entire app flashes
            // white on every launch before the SQLite read completes.
            let seeded = ThemeCache.loadTheme()
            self.readerTheme = seeded
            var appearance = ReaderAppearanceSettings()
            appearance.theme = seeded
            self.cachedAppearance = appearance
        }
    }

    /// Synchronous read/write of the last-known theme so `State.init`
    /// can paint the correct background before SQLite responds.
    enum ThemeCache {
        static let key = "stower.readerTheme"

        static func loadTheme() -> ReaderTheme {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let theme = ReaderTheme(rawValue: raw)
            else { return .sepia }
            return theme
        }

        static func saveTheme(_ theme: ReaderTheme) {
            UserDefaults.standard.set(theme.rawValue, forKey: key)
        }
    }

    public enum Action: Equatable {
        case onAppear
        case startupFinished
        case startupFailed(String)
        case readerAppearanceLoaded(ReaderAppearanceSettings)
        case readerAppearanceFailed(String)
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

    @Dependency(\.cloudSyncClient) var cloudSyncClient
    @Dependency(\.stowerRepository) var repository
    @Dependency(\.urlIngestionClient) var ingestionClient
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.defaultSyncEngine) var syncEngine
    @Dependency(\.continuousClock) var clock
    @Dependency(\.context) var context

    public var body: some ReducerOf<Self> {
        Scope(state: \.sidebar, action: \.sidebar) {
            SidebarFeature()
        }
        Scope(state: \.library, action: \.library) {
            LibraryFeature()
        }
        Scope(state: \.settings, action: \.settings) {
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
                let clock = self.clock
                let periodicSync: Effect<Action> =
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
                    .run { _ in _ = try? await repository.purgeOldTrash() },
                    .run { send in
                        do {
                            try await cloudSyncClient.start()
                            _ = try await repository.enqueueHydrationJobsForMissingContent()
                            try await processIngestionJobs(
                                repository: repository,
                                ingestionClient: ingestionClient
                            )
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

            case .readerAppearanceLoaded(let appearance):
                state.cachedAppearance = appearance
                state.readerTheme = appearance.theme
                ThemeCache.saveTheme(appearance.theme)
                return .none

            case .readerAppearanceFailed:
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
                    return .run { send in
                        _ = try? await repository.enqueueHydrationJobsForMissingContent()
                        try? await processIngestionJobs(repository: repository, ingestionClient: ingestionClient)
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
                state.reader = ReaderFeature.State(
                    item: item,
                    appearance: state.cachedAppearance
                )
                return .none

            case .reader(.presented(.themeChanged(let theme))):
                state.readerTheme = theme
                state.cachedAppearance.theme = theme
                ThemeCache.saveTheme(theme)
                return .none

            case .reader(.presented(.saveAppearanceFinished)):
                // Keep cached appearance in sync when reader saves changes
                if let readerAppearance = state.reader?.appearance {
                    state.cachedAppearance = readerAppearance
                    state.readerTheme = readerAppearance.theme
                    ThemeCache.saveTheme(readerAppearance.theme)
                }
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
    }
}

private func processIngestionJobs(
    repository: StowerRepository,
    ingestionClient: URLIngestionClient
) async throws {
    let jobs = try await repository.fetchPendingIngestionJobs()
    for job in jobs {
        switch job.kind {
        case .url:
            let trimmed = job.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed) {
                let result = try await ingestionClient.ingest(url)
                let item = try await repository.createItemFromIngestion(result)

                // Archive all external assets for offline WebView rendering.
                if result.renderFormat == .webView,
                   !result.sourceHTML.isEmpty,
                   let source = result.sourceURL,
                   let baseURL = URL(string: source) {
                    await AssetArchiver.archiveAssets(
                        html: result.sourceHTML,
                        baseURL: baseURL,
                        itemID: item.id
                    )
                }
            } else {
                _ = try await repository.createItemFromIngestion(.sharedText(trimmed))
            }
        case .text:
            _ = try await repository.createItemFromIngestion(.sharedText(job.payload))
        case .hydrate:
            let data = Data(job.payload.utf8)
            let payload = try JSONDecoder().decode(HydrationPayload.self, from: data)
            if let url = URL(string: payload.url) {
                do {
                    try await repository.updateLocalContentStatus(payload.itemID, "downloading", nil)
                    let result = try await ingestionClient.ingest(url)
                    try await repository.hydrateItemContent(payload.itemID, result)

                    // Archive assets for offline WebView rendering.
                    if result.renderFormat == .webView,
                       !result.sourceHTML.isEmpty,
                       let source = result.sourceURL,
                       let baseURL = URL(string: source) {
                        await AssetArchiver.archiveAssets(
                            html: result.sourceHTML,
                            baseURL: baseURL,
                            itemID: payload.itemID
                        )
                    }
                } catch {
                    try? await repository.updateLocalContentStatus(payload.itemID, "failed", error.localizedDescription)
                }
            }
        }
        try await repository.markIngestionJobProcessed(job.id)
    }
}
