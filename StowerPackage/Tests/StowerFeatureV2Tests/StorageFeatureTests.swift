import ComposableArchitecture
import Foundation
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct StorageFeatureTests {
    private static func makeSnapshot(archiveBytes: Int = 1024) -> StorageSnapshot {
        var snapshot = StorageSnapshot()
        snapshot.archiveBytes = archiveBytes
        snapshot.computedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return snapshot
    }

    @Test
    func task_loadsSnapshot() async {
        let snapshot = Self.makeSnapshot()
        let store = TestStore(initialState: StorageFeature.State()) {
            StorageFeature()
        } withDependencies: {
            $0.storageUsageClient = StorageUsageClient(
                computeSnapshot: { _ in snapshot },
                runMaintenance: { _ in MaintenanceReport() }
            )
        }

        await store.send(.task) {
            $0.isComputing = true
        }
        await store.receive(.snapshotLoaded(snapshot)) {
            $0.isComputing = false
            $0.snapshot = snapshot
        }
    }

    @Test
    func reclaim_runsMaintenanceThenRefreshesSnapshot() async {
        let report = MaintenanceReport(freedBytes: 2048, steps: ["Swept stranded imports"])
        let snapshot = Self.makeSnapshot(archiveBytes: 64)
        let store = TestStore(initialState: StorageFeature.State()) {
            StorageFeature()
        } withDependencies: {
            $0.storageUsageClient = StorageUsageClient(
                computeSnapshot: { force in
                    #expect(force)
                    return snapshot
                },
                runMaintenance: { trigger in
                    #expect(trigger == .userReclaim)
                    return report
                }
            )
        }

        await store.send(.reclaimTapped) {
            $0.maintenance = .running
        }
        await store.receive(.maintenanceFinished(report)) {
            $0.maintenance = .finished(report)
            $0.isComputing = true
        }
        await store.receive(.snapshotLoaded(snapshot)) {
            $0.isComputing = false
            $0.snapshot = snapshot
        }
    }

    @Test
    func reclaim_failureSurfacesMessage() async {
        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let store = TestStore(initialState: StorageFeature.State()) {
            StorageFeature()
        } withDependencies: {
            $0.storageUsageClient = StorageUsageClient(
                computeSnapshot: { _ in StorageSnapshot() },
                runMaintenance: { _ in throw Failure() }
            )
        }

        await store.send(.reclaimTapped) {
            $0.maintenance = .running
        }
        await store.receive(.maintenanceFailed("disk full")) {
            $0.maintenance = .failed("disk full")
        }
    }

    @Test
    func reclaim_isNotReentrantWhileRunning() async {
        let store = TestStore(initialState: StorageFeature.State()) {
            StorageFeature()
        } withDependencies: {
            $0.storageUsageClient = StorageUsageClient(
                computeSnapshot: { _ in StorageSnapshot() },
                runMaintenance: { _ in
                    try await Task.never()
                }
            )
        }

        await store.send(.reclaimTapped) {
            $0.maintenance = .running
        }
        // A second tap while running must be ignored entirely.
        await store.send(.reclaimTapped)
        await store.skipInFlightEffects()
    }
}
