import Foundation
import SQLiteData
#if canImport(CloudKit)
import CloudKit
#endif

extension StowerDatabase {
    static func makeCloudSyncClient(
        database: any DatabaseWriter,
        syncEngineDelegate: (any SyncEngineDelegate)?
    ) -> (client: CloudSyncClient, syncEngine: SyncEngine?) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: CloudSyncStatus.self,
            bufferingPolicy: .bufferingNewest(10)
        )
        continuation.yield(.starting)

        do {
            let delegate = syncEngineDelegate ?? StowerSyncEngineDelegate(emit: { continuation.yield($0) })
            let syncEngine: SyncEngine = try SyncEngine(
                for: database,
                tables: SavedItemSyncTable.self,
                TagSyncTable.self,
                ItemTagSyncTable.self,
                containerIdentifier: StowerDatabase.cloudKitContainerID,
                delegate: delegate
            )

            let coordinator = CloudSyncCoordinator(
                syncNow: { try await syncEngine.syncChanges() },
                emit: { continuation.yield($0) }
            )

            let startImpl: @Sendable () async throws -> Void = {
                continuation.yield(CloudSyncStatus(state: .starting))
#if canImport(CloudKit)
                do {
                    let accountStatus = try await CKContainer.default().accountStatus()
                    guard accountStatus == .available else {
                        continuation.yield(
                            CloudSyncStatus(state: .unavailable("iCloud unavailable (\(String(describing: accountStatus)))."))
                        )
                        return
                    }
                } catch {
                    continuation.yield(CloudSyncStatus(state: .unavailable(error.localizedDescription)))
                    return
                }
#endif
                try await syncEngine.start()
                continuation.yield(CloudSyncStatus(state: .available))
                try await coordinator.syncNow()
            }
            let sendChangesImpl: @Sendable () async throws -> Void = {
                try await coordinator.syncNow()
            }
            let scheduleSendChangesImpl: @Sendable () async -> Void = {
                await coordinator.scheduleSync()
            }
            let statusStreamImpl: @Sendable () -> AsyncStream<CloudSyncStatus> = { stream }

            let client = CloudSyncClient(
                start: startImpl,
                sendChanges: sendChangesImpl,
                scheduleSendChanges: scheduleSendChangesImpl,
                statusStream: statusStreamImpl
            )
            return (client: client, syncEngine: syncEngine)
        } catch {
            continuation.yield(CloudSyncStatus(state: .unavailable(error.localizedDescription)))
            let statusStreamImpl: @Sendable () -> AsyncStream<CloudSyncStatus> = { stream }
            let client = CloudSyncClient(
                start: {},
                sendChanges: {},
                scheduleSendChanges: {},
                statusStream: statusStreamImpl
            )
            return (client: client, syncEngine: nil)
        }
    }
}
