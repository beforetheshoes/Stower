import ComposableArchitecture
import Foundation
import SQLiteData
import StowerData

/// CloudKit sync as the app sees it: its status, the periodic nudge, the
/// pass that hydrates records a sync just delivered, and the local reset
/// the engine can ask for.
@Reducer
public struct SyncFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var status: CloudSyncStatus = .starting
        /// The post-sync pass was interrupted or skipped in the background
        /// and should run on the next activation.
        public var followUpPending = false
        var isFollowUpRunning = false
        /// Mirrors the app's scene state: follow-up scans wait for the
        /// foreground so they cannot be holding a lock when iOS suspends
        /// the process.
        var isSceneInBackground = false
        @Presents public var resetAlert: AlertState<Action.ResetAlert>?

        public init() {}
    }

    public enum Action: Equatable {
        case onAppear
        case statusChanged(CloudSyncStatus)
        case followUpFinished
        /// The pass hit a suspended database; it re-runs on activation.
        case followUpInterrupted
        case sceneDidEnterBackground
        case sceneDidBecomeActive
        case resetAlert(PresentationAction<ResetAlert>)
        case delegate(Delegate)

        public enum ResetAlert: Equatable {
            case confirmReset
            case cancel
        }

        public enum Delegate: Equatable {
            /// The scans are done; anything they queued should be drained.
            case followUpScansFinished
            case resetFailed(String)
        }
    }

    enum CancelID {
        case followUp
        case status
        case periodicSync
    }

    @Dependency(\.cloudSyncClient)
    var cloudSyncClient
    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.defaultSyncEngine)
    var syncEngine
    @Dependency(\.continuousClock)
    var clock
    @Dependency(\.context)
    var context

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                let cloudSyncClient = self.cloudSyncClient
                let clock = self.clock
                let periodicSync: EffectOf<Self> =
                    context == .live
                    ? .run { _ in
                        // CloudKit push delivery is not guaranteed (especially
                        // on macOS). While the app is running, periodically
                        // force a sync to pull remote changes.
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
                    .run { send in
                        for await status in cloudSyncClient.statusStream() {
                            await send(.statusChanged(status))
                        }
                    }
                    .cancellable(id: CancelID.status, cancelInFlight: true),
                    periodicSync
                )

            case .statusChanged(let status):
                let previous = state.status
                state.status = status

                // A sync just completed: hydrate whatever it delivered.
                if status.lastSyncSuccess != nil, status.lastSyncSuccess != previous.lastSyncSuccess {
                    guard !state.isSceneInBackground else {
                        state.followUpPending = true
                        return .none
                    }
                    return startFollowUp(state: &state)
                }

                if case .needsLocalReset(let reason) = status.state {
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
                }
                return .none

            case .followUpFinished:
                state.isFollowUpRunning = false
                return .none

            case .followUpInterrupted:
                state.isFollowUpRunning = false
                state.followUpPending = true
                return .none

            case .sceneDidEnterBackground:
                state.isSceneInBackground = true
                if state.isFollowUpRunning {
                    state.isFollowUpRunning = false
                    state.followUpPending = true
                }
                return .cancel(id: CancelID.followUp)

            case .sceneDidBecomeActive:
                state.isSceneInBackground = false
                guard state.followUpPending else { return .none }
                return startFollowUp(state: &state)

            case .resetAlert(.presented(.confirmReset)):
                let repository = self.repository
                let syncEngine = self.syncEngine
                return .run { send in
                    do {
                        // Clear local CloudKit state for synced tables (does
                        // not delete iCloud data), then the local-only
                        // tables. If the first step fails the second is not
                        // attempted: wiping local content while the sync
                        // state is intact would leave the two disagreeing.
                        try await syncEngine.deleteLocalData()
                        try await repository.resetLocalData()
                    } catch {
                        await send(.delegate(.resetFailed("Reset did not finish: \(error.localizedDescription)")))
                    }
                }

            case .resetAlert, .delegate:
                return .none
            }
        }
        .ifLet(\.$resetAlert, action: \.resetAlert)
    }

    /// Hydrates content for records that just arrived through CloudKit.
    private func startFollowUp(state: inout State) -> EffectOf<Self> {
        state.followUpPending = false
        state.isFollowUpRunning = true
        let repository = self.repository
        return .run { send in
            // Each scan is independent: one failing must not stop the rest.
            // A scan refused because the database is suspended is different —
            // the whole pass is repeated on the next activation.
            let scans: [@Sendable () async throws -> Int] = [
                repository.enqueueHydrationJobsForMissingContent,
                repository.hydratePDFItemsFromSyncedContent,
                repository.hydrateTextItemsFromSyncedContent,
                repository.hydrateWebsiteItemsFromSyncedContent,
                repository.hydrateBookItemsFromSyncedContent,
                repository.reconcileOrphanedTagAssignments,
            ]
            for scan in scans {
                do {
                    _ = try await scan()
                } catch where error.isDatabaseSuspension {
                    await send(.followUpInterrupted)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    reportIssue(error)
                }
            }
            await send(.delegate(.followUpScansFinished))
            await send(.followUpFinished)
        }
        .cancellable(id: CancelID.followUp, cancelInFlight: true)
    }
}
