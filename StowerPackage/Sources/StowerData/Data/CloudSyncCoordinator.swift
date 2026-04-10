import Foundation

actor CloudSyncCoordinator {
    private let syncNowImpl: @Sendable () async throws -> Void
    private let emit: @Sendable (CloudSyncStatus) -> Void
    private var pendingTask: Task<Void, Never>?

    init(
        syncNow: @escaping @Sendable () async throws -> Void,
        emit: @escaping @Sendable (CloudSyncStatus) -> Void
    ) {
        self.syncNowImpl = syncNow
        self.emit = emit
    }

    func scheduleSync() async {
        pendingTask?.cancel()
        pendingTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            _ = try? await self.syncNow()
        }
    }

    func syncNow() async throws {
        pendingTask?.cancel()
        pendingTask = nil

        let now = Date.now
        emit(CloudSyncStatus(state: .available, lastSyncAttempt: now, lastSyncSuccess: nil))
        do {
            try await syncNowImpl()
            emit(CloudSyncStatus(state: .available, lastSyncAttempt: now, lastSyncSuccess: now))
        } catch {
            emit(CloudSyncStatus(state: .error(error.localizedDescription), lastSyncAttempt: now, lastSyncSuccess: nil))
            throw error
        }
    }
}
