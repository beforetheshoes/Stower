import ComposableArchitecture
import Foundation

/// Progress of the bulk re-extract maintenance action.
///
/// Re-extraction rebuilds a saved article from its source URL through the
/// current capture pipeline. Extraction fixes only apply at save time, so
/// articles saved by an older build keep whatever structure that build
/// produced until they are rebuilt.
public enum LibraryReextractionState: Equatable, Sendable {
    case idle
    case running(Progress)
    case finished(Summary)

    public struct Progress: Equatable, Sendable {
        public var completed: Int
        public var total: Int
        public var failed: Int
        public var currentTitle: String?

        public init(completed: Int = 0, total: Int = 0, failed: Int = 0, currentTitle: String? = nil) {
            self.completed = completed
            self.total = total
            self.failed = failed
            self.currentTitle = currentTitle
        }

        public var fraction: Double {
            guard total > 0 else { return 0 }
            return Double(completed) / Double(total)
        }
    }

    public struct Summary: Equatable, Sendable {
        public var succeeded: Int
        public var failed: Int
        public var wasCancelled: Bool

        public init(succeeded: Int, failed: Int, wasCancelled: Bool) {
            self.succeeded = succeeded
            self.failed = failed
            self.wasCancelled = wasCancelled
        }
    }

    public var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

@Reducer
public struct SettingsFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var settings = ImageDownloadSettings()
        public var errorMessage: String?
        public var cloudSyncStatus: CloudSyncStatus = .starting
        public var diagnostics: SyncDiagnostics?
        public var reextraction: LibraryReextractionState = .idle
        public var storage = StorageFeature.State()

        public init() {}
    }

    public enum Action: Equatable {
        case load
        case response(ImageDownloadSettings)
        case failed(String)
        case globalAutoDownloadChanged(Bool)
        case askForNewSourcesChanged(Bool)
        case save
        case saveFinished
        case saveFailed(String)
        case refreshDiagnostics
        case diagnosticsLoaded(SyncDiagnostics)

        // MARK: Bulk re-extract
        case reextractLibraryTapped
        case reextractCancelTapped
        case reextractStarted(total: Int)
        case reextractItemFinished(title: String?, succeeded: Bool)
        case reextractCompleted(wasCancelled: Bool)
        case reextractDismissed

        case storage(StorageFeature.Action)
    }

    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.syncDiagnosticsClient)
    var syncDiagnosticsClient
    @Dependency(\.articleSaveClient)
    var articleSaveClient
    @Dependency(\.ingestionCoordinator)
    var ingestionCoordinator

    public var body: some ReducerOf<Self> {
        Scope(state: \.storage, action: \.storage) {
            StorageFeature()
        }
        Reduce { state, action in
            switch action {
            case .storage:
                return .none

            case .load:
                let repository = self.repository
                return .run { send in
                    do {
                        let settings = try await repository.loadSettings()
                        await send(.response(settings))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .response(let settings):
                state.settings = settings
                state.errorMessage = nil
                return .send(.refreshDiagnostics)

            case .failed(let error):
                state.errorMessage = error
                return .none

            case .globalAutoDownloadChanged(let enabled):
                state.settings.globalAutoDownload = enabled
                return .send(.save)

            case .askForNewSourcesChanged(let enabled):
                state.settings.askForNewSources = enabled
                return .send(.save)

            case .save:
                let repository = self.repository
                return .run { [settings = state.settings] send in
                    do {
                        try await repository.saveSettings(settings)
                        await send(.saveFinished)
                    } catch {
                        await send(.saveFailed(error.localizedDescription))
                    }
                }

            case .saveFailed(let error):
                state.errorMessage = error
                return .none

            case .saveFinished:
                return .none

            case .refreshDiagnostics:
                #if DEBUG
                let client = self.syncDiagnosticsClient
                return .run { send in
                    do {
                        let diagnostics = try await client.load()
                        await send(.diagnosticsLoaded(diagnostics))
                    } catch {
                        // Diagnostics are best-effort.
                    }
                }
                #else
                return .none
                #endif

            case .diagnosticsLoaded(let diagnostics):
                state.diagnostics = diagnostics
                return .none

            // MARK: Bulk re-extract

            case .reextractLibraryTapped:
                guard !state.reextraction.isRunning else { return .none }
                state.reextraction = .running(LibraryReextractionState.Progress())
                state.errorMessage = nil

                let repository = self.repository
                let articleSaveClient = self.articleSaveClient
                let ingestionCoordinator = self.ingestionCoordinator
                return .run { send in
                    let items = (try? await repository.fetchReextractableItems()) ?? []
                    await send(.reextractStarted(total: items.count))
                    guard !items.isEmpty else {
                        await send(.reextractCompleted(wasCancelled: false))
                        return
                    }

                    // Each refresh drives a WebKit capture. Running through
                    // the ingestion coordinator keeps this from overlapping a
                    // queue drain, so shared URLs and the rebuild never fight
                    // over the same WebView and database writes.
                    try? await ingestionCoordinator.run {
                        for item in items {
                            if Task.isCancelled {
                                return
                            }
                            guard let source = item.sourceURL,
                                  let url = URL(string: source)
                            else {
                                await send(.reextractItemFinished(title: item.title, succeeded: false))
                                continue
                            }
                            do {
                                _ = try await articleSaveClient.refresh(item.id, url)
                                await send(.reextractItemFinished(title: item.title, succeeded: true))
                            } catch is CancellationError {
                                return
                            } catch {
                                // One unreachable or paywalled article must not
                                // stop the rebuild — record it and carry on.
                                await send(.reextractItemFinished(title: item.title, succeeded: false))
                            }
                        }
                    }
                    await send(.reextractCompleted(wasCancelled: Task.isCancelled))
                }
                .cancellable(id: CancelID.reextraction, cancelInFlight: true)

            case .reextractStarted(let total):
                guard case .running(var progress) = state.reextraction else { return .none }
                progress.total = total
                state.reextraction = .running(progress)
                return .none

            case let .reextractItemFinished(title, succeeded):
                guard case .running(var progress) = state.reextraction else { return .none }
                progress.completed += 1
                if !succeeded { progress.failed += 1 }
                progress.currentTitle = title
                state.reextraction = .running(progress)
                return .none

            case .reextractCancelTapped:
                guard case .running(let progress) = state.reextraction else { return .none }
                state.reextraction = .finished(
                    LibraryReextractionState.Summary(
                        succeeded: progress.completed - progress.failed,
                        failed: progress.failed,
                        wasCancelled: true
                    )
                )
                return .cancel(id: CancelID.reextraction)

            case .reextractCompleted(let wasCancelled):
                guard case .running(let progress) = state.reextraction else { return .none }
                state.reextraction = .finished(
                    LibraryReextractionState.Summary(
                        succeeded: progress.completed - progress.failed,
                        failed: progress.failed,
                        wasCancelled: wasCancelled
                    )
                )
                return .none

            case .reextractDismissed:
                state.reextraction = .idle
                return .none
            }
        }
    }

    enum CancelID {
        case reextraction
    }
}
