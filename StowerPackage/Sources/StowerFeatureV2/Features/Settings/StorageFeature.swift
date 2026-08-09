import ComposableArchitecture
import Foundation

/// The Settings → Storage section: usage breakdown plus the user-triggered
/// "Reclaim Space" maintenance pass. Snapshots are computed lazily when the
/// section appears — a full scan walks every archive directory, so it must
/// never run at app launch.
@Reducer
public struct StorageFeature {
    public init() {}

    public enum MaintenanceState: Equatable, Sendable {
        case idle
        case running
        case finished(MaintenanceReport)
        case failed(String)

        public var isRunning: Bool { self == .running }
    }

    @ObservableState
    public struct State: Equatable {
        public var snapshot: StorageSnapshot?
        public var isComputing = false
        public var maintenance: MaintenanceState = .idle
        public var errorMessage: String?
        /// Automatic-offload budget; nil disables the eviction pass.
        public var budgetBytes: Int?
        public var isOffloading = false
        public var lastOffloadReport: StorageOffloadService.EvictionReport?

        public init() {}
    }

    public enum Action: Equatable {
        case task
        case refresh
        case snapshotLoaded(StorageSnapshot)
        case snapshotFailed(String)
        case reclaimTapped
        case maintenanceFinished(MaintenanceReport)
        case maintenanceFailed(String)
        case budgetLoaded(Int?)
        case budgetChanged(Int?)
        case offloadNowTapped
        case offloadFinished(StorageOffloadService.EvictionReport)
        case offloadFailed(String)
    }

    @Dependency(\.storageUsageClient)
    var storageUsageClient
    @Dependency(\.itemStorageClient)
    var itemStorageClient
    @Dependency(\.stowerRepository)
    var repository

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                guard !state.isComputing else { return .none }
                state.isComputing = true
                let storageUsageClient = self.storageUsageClient
                let itemStorageClient = self.itemStorageClient
                return .run { send in
                    var budget: Int?
                    if let loaded = try? await itemStorageClient.budgetBytes() {
                        budget = loaded
                    }
                    await send(.budgetLoaded(budget))
                    do {
                        let snapshot = try await storageUsageClient.computeSnapshot(false)
                        await send(.snapshotLoaded(snapshot))
                    } catch {
                        await send(.snapshotFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.snapshot, cancelInFlight: true)

            case .budgetLoaded(let budget):
                state.budgetBytes = budget
                return .none

            case .budgetChanged(let budget):
                state.budgetBytes = budget
                let itemStorageClient = self.itemStorageClient
                let repository = self.repository
                return .run { send in
                    try? await itemStorageClient.setBudgetBytes(budget)
                    guard budget != nil else { return }
                    do {
                        let report = try await StorageOffloadService.runEviction(repository: repository)
                        if report.evictedCount > 0 {
                            await send(.offloadFinished(report))
                        }
                    } catch {
                        await send(.offloadFailed(error.localizedDescription))
                    }
                }

            case .offloadNowTapped:
                guard !state.isOffloading else { return .none }
                state.isOffloading = true
                state.errorMessage = nil
                let repository = self.repository
                return .run { send in
                    do {
                        // Budget 0 evicts every eligible read item.
                        let report = try await StorageOffloadService.runEviction(
                            repository: repository,
                            budgetOverride: 0
                        )
                        await send(.offloadFinished(report))
                    } catch {
                        await send(.offloadFailed(error.localizedDescription))
                    }
                }

            case .offloadFinished(let report):
                state.isOffloading = false
                state.lastOffloadReport = report
                state.isComputing = true
                return loadSnapshot(force: true)

            case .offloadFailed(let message):
                state.isOffloading = false
                state.errorMessage = message
                return .none

            case .refresh:
                guard !state.isComputing else { return .none }
                state.isComputing = true
                return loadSnapshot(force: true)

            case .snapshotLoaded(let snapshot):
                state.isComputing = false
                state.snapshot = snapshot
                state.errorMessage = nil
                return .none

            case .snapshotFailed(let message):
                state.isComputing = false
                state.errorMessage = message
                return .none

            case .reclaimTapped:
                guard !state.maintenance.isRunning else { return .none }
                state.maintenance = .running
                state.errorMessage = nil
                let client = self.storageUsageClient
                return .run { send in
                    do {
                        let report = try await client.runMaintenance(.userReclaim)
                        await send(.maintenanceFinished(report))
                    } catch {
                        await send(.maintenanceFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.maintenance, cancelInFlight: true)

            case .maintenanceFinished(let report):
                state.maintenance = .finished(report)
                state.isComputing = true
                return loadSnapshot(force: true)

            case .maintenanceFailed(let message):
                state.maintenance = .failed(message)
                return .none
            }
        }
    }

    private func loadSnapshot(force: Bool) -> EffectOf<Self> {
        let client = self.storageUsageClient
        return .run { send in
            do {
                let snapshot = try await client.computeSnapshot(force)
                await send(.snapshotLoaded(snapshot))
            } catch {
                await send(.snapshotFailed(error.localizedDescription))
            }
        }
        .cancellable(id: CancelID.snapshot, cancelInFlight: true)
    }

    enum CancelID {
        case snapshot
        case maintenance
    }
}
