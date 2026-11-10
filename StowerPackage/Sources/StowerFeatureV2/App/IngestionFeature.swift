import ComposableArchitecture
import Foundation
import StowerData

/// The ingestion queue as the app sees it: when to drain it, what is still
/// being saved, and what failed.
///
/// `AppFeature` decides *when* (a save was queued, the scene became active);
/// this feature owns the drain itself and the two pieces of UI state it
/// produces. The job pipeline is in `IngestionJobProcessor.swift`.
@Reducer
public struct IngestionFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var failedImports = [FailedImport]()
        /// Saves queued from this app that are still being fetched. Drives
        /// the "Saving…" notice.
        public var pendingSaveCount = 0
        /// Drains started here that have not reported back. The notice
        /// clears when the last one finishes.
        var activeDrainCount = 0

        public init() {}
    }

    public enum Action: Equatable {
        /// A save from this app is in the queue: show progress and fetch it
        /// now rather than at the next launch.
        case saveQueued
        /// Something else may have queued work (the share extension, a sync).
        case drainRequested
        case retryFailedImportsTapped
        case dismissFailedImportsTapped
        case failedImportsLoaded([FailedImport])
        case drainFinished
        /// Cancels the drains: see `AppFeature`'s `sceneDidEnterBackground`.
        case sceneDidEnterBackground
    }

    enum CancelID {
        case drain
    }

    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.urlIngestionClient)
    var ingestionClient
    @Dependency(\.pdfIngestionClient)
    var pdfIngestionClient
    @Dependency(\.textIngestionClient)
    var textIngestionClient
    @Dependency(\.date)
    var date
    @Dependency(\.ingestionCoordinator)
    var ingestionCoordinator

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .saveQueued:
                state.pendingSaveCount += 1
                return drain(state: &state)

            case .drainRequested:
                return drain(state: &state)

            case .retryFailedImportsTapped:
                state.failedImports = []
                return drain(state: &state, retryingFailed: true)

            case .dismissFailedImportsTapped:
                let repository = self.repository
                let now = date.now
                state.failedImports = []
                return .run { _ in
                    await reportingErrors { try await repository.dismissFailedIngestionJobs(now) }
                }

            case .failedImportsLoaded(let imports):
                state.failedImports = imports
                return .none

            case .drainFinished:
                // Drains are serialized and each one empties the queue, so
                // once none is outstanding every queued save has been handled.
                state.activeDrainCount = max(0, state.activeDrainCount - 1)
                if state.activeDrainCount == 0 {
                    state.pendingSaveCount = 0
                }
                return .none

            case .sceneDidEnterBackground:
                // Cancelled drains never report back. `pendingSaveCount` is
                // left alone so the "Saving…" notice is still there on return;
                // the drain that every activation starts clears it.
                state.activeDrainCount = 0
                return .cancel(id: CancelID.drain)
            }
        }
    }

    /// Drains the queue and refreshes the failed-import list. Every
    /// activation starts a fresh drain, so whatever a cancelled one did not
    /// finish runs again then.
    private func drain(state: inout State, retryingFailed: Bool = false) -> EffectOf<Self> {
        state.activeDrainCount += 1
        let repository = self.repository
        let ingestionClient = self.ingestionClient
        let pdfIngestionClient = self.pdfIngestionClient
        let textIngestionClient = self.textIngestionClient
        let date = self.date
        let ingestionCoordinator = self.ingestionCoordinator
        return .run { send in
            if retryingFailed {
                await reportingErrors { try await repository.retryFailedIngestionJobs() }
            }
            try? await ingestionCoordinator.run {
                try await processIngestionJobs(
                    repository: repository,
                    ingestionClient: ingestionClient,
                    pdfIngestionClient: pdfIngestionClient,
                    textIngestionClient: textIngestionClient,
                    ingestionCoordinator: ingestionCoordinator
                ) { date.now }
            }
            let jobs = await reportingErrors { try await repository.fetchFailedIngestionJobs() } ?? []
            await send(.failedImportsLoaded(FailedImport.list(from: jobs)))
            await send(.drainFinished)
        }
        .cancellable(id: CancelID.drain)
    }
}
