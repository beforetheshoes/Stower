import Foundation
import OSLog
import SQLiteData
#if canImport(CloudKit)
import CloudKit
#endif

private let kCloudSyncLogger = Logger(subsystem: "com.ryanleewilliams.stower", category: "CloudSync")

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
            let delegate = syncEngineDelegate ?? StowerSyncEngineDelegate { continuation.yield($0) }
            // TagSyncTable and ItemTagSyncTable are fully self-contained
            // sync tables — unlike SavedPDFContentSyncTable (which has
            // _hydratePDFItemsFromSyncedContent), they have no post-receive
            // hydration step because the domain model reads directly from
            // the sync tables.
            //
            // Known limitation: deleting a tag on Device A removes its
            // ItemTagSyncTable junction rows locally, but Device B only
            // receives the TagSyncTable deletion via CloudKit — the orphaned
            // junction rows on Device B are not automatically cleaned up.
            // TODO: Add a _reconcileOrphanedJunctionRows sweep on launch or
            // after sync to garbage-collect junctions referencing deleted tags.
            let syncEngine: SyncEngine = try SyncEngine(
                for: database,
                tables: SavedItemSyncTable.self,
                TagSyncTable.self,
                ItemTagSyncTable.self,
                SavedPDFContentSyncTable.self,
                SavedTextContentSyncTable.self,
                SavedWebsiteArchiveSyncTable.self,
                SavedArticleCaptureSyncTable.self,
                SavedArticleCaptureChunkSyncTable.self,
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
                    let accountStatus = try await CKContainer(
                        identifier: StowerDatabase.cloudKitContainerID
                    ).accountStatus()
                    guard accountStatus == .available else {
                        let message = "iCloud unavailable (\(String(describing: accountStatus)))."
                        kCloudSyncLogger.error("CloudKit: \(message, privacy: .public)")
                        continuation.yield(
                            CloudSyncStatus(state: .unavailable(message))
                        )
                        return
                    }
                } catch {
                    let detailed = detailedErrorDescription(error)
                    kCloudSyncLogger.error("CloudKit account check failed: \(detailed, privacy: .public)")
                    continuation.yield(CloudSyncStatus(state: .unavailable(detailed)))
                    return
                }
#endif
                do {
                    try await syncEngine.start()
                } catch {
                    let detailed = detailedErrorDescription(error)
                    kCloudSyncLogger.error("CloudKit syncEngine.start() failed: \(detailed, privacy: .public)")
                    continuation.yield(CloudSyncStatus(state: .error(detailed)))
                    throw error
                }
                continuation.yield(CloudSyncStatus(state: .available))
                do {
                    try await coordinator.syncNow()
                } catch {
                    let detailed = detailedErrorDescription(error)
                    kCloudSyncLogger.error("CloudKit initial syncNow() failed: \(detailed, privacy: .public)")
                    continuation.yield(CloudSyncStatus(state: .error(detailed)))
                    throw error
                }
            }
            let sendChangesImpl: @Sendable () async throws -> Void = {
                do {
                    try await coordinator.syncNow()
                } catch {
                    let detailed = detailedErrorDescription(error)
                    kCloudSyncLogger.error("CloudKit sendChanges() failed: \(detailed, privacy: .public)")
                    continuation.yield(CloudSyncStatus(state: .error(detailed)))
                    throw error
                }
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
            let detailed = detailedErrorDescription(error)
            kCloudSyncLogger.error("CloudKit SyncEngine construction failed: \(detailed, privacy: .public)")
            continuation.yield(CloudSyncStatus(state: .error(detailed)))
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

/// SQLiteData's `SyncEngine.SchemaError` has a useful `debugDescription`
/// field that names the exact reason (cycle detected, invalid foreign key,
/// uniqueness constraint, no CloudKit container, etc.) but its `Error`
/// conformance's `localizedDescription` just returns the generic "Could
/// not synchronize data with iCloud." that you saw in the settings sheet.
/// Every other Swift error still routes through `localizedDescription`.
///
/// Reflection (via `String(reflecting:)`) picks up both the package-private
/// fields on `SchemaError` and the userInfo of NSErrors — whichever one
/// happens to be the underlying failure — without us needing access to
/// SQLiteData's internal types.
private func detailedErrorDescription(_ error: Error) -> String {
    let localized = error.localizedDescription
    let reflected = String(reflecting: error)
    // If reflection gave us more than just the type name and the generic
    // error, prefer it; otherwise fall back to localizedDescription.
    if reflected.count > localized.count + 20 {
        return reflected
    }
    return localized
}
