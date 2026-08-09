import Dependencies
import Foundation
import OSLog
import SQLiteData

private let kMaintenanceLogger = Logger(subsystem: "com.ryanleewilliams.stower", category: "StorageMaintenance")

/// Size and fragmentation statistics for the main database file.
public struct DatabaseStorageStats: Equatable, Sendable {
    public var pageCount: Int
    public var pageSize: Int
    public var freelistCount: Int
    public var walBytes: Int

    /// Bytes occupied by the main database file.
    public var fileBytes: Int { pageCount * pageSize }
    /// Bytes held by free pages that only a VACUUM can return to the system.
    public var reclaimableBytes: Int { freelistCount * pageSize }

    public init(pageCount: Int = 0, pageSize: Int = 0, freelistCount: Int = 0, walBytes: Int = 0) {
        self.pageCount = pageCount
        self.pageSize = pageSize
        self.freelistCount = freelistCount
        self.walBytes = walBytes
    }
}

/// Database-side storage maintenance: orphaned sync-row cleanup, dead blob
/// removal, size statistics, and space reclamation. File-system sweeps live in
/// `StorageUsageClient` (StowerFeature); this client owns everything that
/// touches `stower.sqlite`.
public struct StorageMaintenanceClient: Sendable {
    /// Current size/fragmentation stats for the database file.
    public var databaseStats: @Sendable () async throws -> DatabaseStorageStats
    /// Deletes rows from the legacy `savedImageAssetLocalTables` blob store,
    /// which nothing has written or read for several schema versions.
    /// Returns the number of rows removed.
    public var clearDeadImageAssetBlobs: @Sendable () async throws -> Int
    /// Two-pass quarantine sweep of content sync rows whose item is gone.
    /// Returns the number of rows deleted this pass. Callers must only invoke
    /// this while CloudKit sync is healthy — see the quarantine rationale on
    /// `OrphanCandidateLocalTable`.
    public var sweepOrphanedSyncRows: @Sendable () async throws -> Int
    /// Absolute payload paths of ingestion jobs that may still be retried.
    /// The staging-directory sweeper must never delete these.
    public var activeJobPayloadPaths: @Sendable () async throws -> Set<String>
    /// Truncating WAL checkpoint.
    public var checkpoint: @Sendable () async throws -> Void
    /// Full VACUUM. Throws `StorageMaintenanceError.insufficientDiskSpace`
    /// when the volume lacks room for the rebuilt copy. Callers are
    /// responsible for only invoking this while the app is in the foreground —
    /// VACUUM holds an exclusive lock on the shared App Group file, which is
    /// fatal (0xDEAD10CC) if the process is suspended mid-run.
    public var vacuum: @Sendable () async throws -> Void

    public init(
        databaseStats: @escaping @Sendable () async throws -> DatabaseStorageStats,
        clearDeadImageAssetBlobs: @escaping @Sendable () async throws -> Int,
        sweepOrphanedSyncRows: @escaping @Sendable () async throws -> Int,
        activeJobPayloadPaths: @escaping @Sendable () async throws -> Set<String>,
        checkpoint: @escaping @Sendable () async throws -> Void,
        vacuum: @escaping @Sendable () async throws -> Void
    ) {
        self.databaseStats = databaseStats
        self.clearDeadImageAssetBlobs = clearDeadImageAssetBlobs
        self.sweepOrphanedSyncRows = sweepOrphanedSyncRows
        self.activeJobPayloadPaths = activeJobPayloadPaths
        self.checkpoint = checkpoint
        self.vacuum = vacuum
    }

    public static let noop = Self(
        databaseStats: { DatabaseStorageStats() },
        clearDeadImageAssetBlobs: { 0 },
        sweepOrphanedSyncRows: { 0 },
        activeJobPayloadPaths: { [] },
        checkpoint: {},
        vacuum: {}
    )
}

public enum StorageMaintenanceError: Error, Equatable, Sendable {
    /// VACUUM needs roughly a full copy of the database; the volume didn't
    /// have it. Carries (requiredBytes, availableBytes).
    case insufficientDiskSpace(required: Int, available: Int)
}

extension StorageMaintenanceClient {
    /// Rows quarantined less recently than this are eligible for deletion.
    public static let orphanQuarantineInterval: TimeInterval = 7 * 24 * 3600

    public static func live(database: any DatabaseWriter) -> Self {
        Self(
            databaseStats: {
                var stats = try await database.read { db in
                    DatabaseStorageStats(
                        pageCount: try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
                        pageSize: try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0,
                        freelistCount: try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                    )
                }
                let walPath = database.path + "-wal"
                if let size = try? FileManager.default
                    .attributesOfItem(atPath: walPath)[.size] as? Int {
                    stats.walBytes = size
                }
                return stats
            },
            clearDeadImageAssetBlobs: {
                try await database.write { db in
                    let count = try SavedImageAssetLocalTable.fetchCount(db)
                    guard count > 0 else { return 0 }
                    try SavedImageAssetLocalTable.delete().execute(db)
                    return count
                }
            },
            sweepOrphanedSyncRows: {
                @Dependency(\.date.now)
                var now
                let deleted = try await database.write { db in
                    try _sweepOrphanedSyncRows(db, now: now)
                }
                if deleted > 0 {
                    kMaintenanceLogger.info("Orphan sweep deleted \(deleted) sync rows")
                }
                return deleted
            },
            activeJobPayloadPaths: {
                try await database.read { db in
                    let payloads = try IngestionJobLocalTable
                        .where { $0.kind.in(["pdf", "website"]) }
                        .where { $0.status.in(["queued", "claimed", "failed"]) }
                        .select(\.payload)
                        .fetchAll(db)
                    return Set(payloads)
                }
            },
            checkpoint: {
                try await database.writeWithoutTransaction { db in
                    try db.checkpoint(.truncate)
                }
            },
            vacuum: {
                let stats = try await database.read { db in
                    DatabaseStorageStats(
                        pageCount: try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
                        pageSize: try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                    )
                }
                let required = Int(Double(stats.fileBytes) * 1.2)
                let available = availableDiskCapacity(forPath: database.path)
                if let available, available < required {
                    throw StorageMaintenanceError.insufficientDiskSpace(
                        required: required,
                        available: available
                    )
                }
                // VACUUM cannot run inside a transaction, and the barrier
                // keeps concurrent readers from observing the rebuild.
                try await database.barrierWriteWithoutTransaction { db in
                    try db.execute(sql: "VACUUM")
                }
            }
        )
    }

    private static func availableDiskCapacity(forPath path: String) -> Int? {
        let url = URL(fileURLWithPath: path).deletingLastPathComponent()
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
    }

    /// One quarantine pass. Split out so tests can drive it with a fixed
    /// clock through `withDependencies`.
    static func _sweepOrphanedSyncRows(_ db: Database, now: Date) throws -> Int {
        let liveItemIDs = Set(try SavedItemSyncTable.select(\.id).fetchAll(db))
        let cutoff = now.addingTimeInterval(-orphanQuarantineInterval)
        var deletedRows = 0

        func sweep(
            tableName: String,
            currentOrphanIDs: Set<UUID>,
            deleteRows: (_ ripeIDs: [UUID]) throws -> Int
        ) throws {
            // Release candidates that are no longer orphaned (their item row
            // arrived after they were quarantined).
            let candidates = try OrphanCandidateLocalTable
                .where { $0.tableName.eq(tableName) }
                .fetchAll(db)
            let healedKeys = candidates
                .filter { !currentOrphanIDs.contains($0.orphanID) }
                .map(\.key)
            if !healedKeys.isEmpty {
                try OrphanCandidateLocalTable
                    .where { $0.key.in(healedKeys) }
                    .delete()
                    .execute(db)
            }

            // Quarantine newly discovered orphans.
            let known = Set(candidates.map(\.orphanID))
            let fresh = currentOrphanIDs.subtracting(known)
            for orphanID in fresh {
                try OrphanCandidateLocalTable.insert {
                    OrphanCandidateLocalTable(
                        key: OrphanCandidateLocalTable.makeKey(tableName: tableName, orphanID: orphanID),
                        tableName: tableName,
                        orphanID: orphanID,
                        firstSeenAt: now
                    )
                }
                .execute(db)
            }

            // Delete rows that have been continuously orphaned for the full
            // quarantine window.
            let ripeIDs = candidates
                .filter { currentOrphanIDs.contains($0.orphanID) && $0.firstSeenAt <= cutoff }
                .map(\.orphanID)
            guard !ripeIDs.isEmpty else { return }
            deletedRows += try deleteRows(ripeIDs)
            let ripeKeys = ripeIDs.map {
                OrphanCandidateLocalTable.makeKey(tableName: tableName, orphanID: $0)
            }
            try OrphanCandidateLocalTable
                .where { $0.key.in(ripeKeys) }
                .delete()
                .execute(db)
        }

        try sweep(
            tableName: SavedWebsiteArchiveSyncTable.tableName,
            currentOrphanIDs: Set(try SavedWebsiteArchiveSyncTable.select(\.id).fetchAll(db))
                .subtracting(liveItemIDs)
        ) { ripe in
            let count = try SavedWebsiteArchiveSyncTable.where { $0.id.in(ripe) }.fetchCount(db)
            try SavedWebsiteArchiveSyncTable.where { $0.id.in(ripe) }.delete().execute(db)
            return count
        }
        try sweep(
            tableName: SavedPDFContentSyncTable.tableName,
            currentOrphanIDs: Set(try SavedPDFContentSyncTable.select(\.id).fetchAll(db))
                .subtracting(liveItemIDs)
        ) { ripe in
            let count = try SavedPDFContentSyncTable.where { $0.id.in(ripe) }.fetchCount(db)
            try SavedPDFContentSyncTable.where { $0.id.in(ripe) }.delete().execute(db)
            return count
        }
        try sweep(
            tableName: SavedTextContentSyncTable.tableName,
            currentOrphanIDs: Set(try SavedTextContentSyncTable.select(\.id).fetchAll(db))
                .subtracting(liveItemIDs)
        ) { ripe in
            let count = try SavedTextContentSyncTable.where { $0.id.in(ripe) }.fetchCount(db)
            try SavedTextContentSyncTable.where { $0.id.in(ripe) }.delete().execute(db)
            return count
        }
        try sweep(
            tableName: SavedAssetManifestSyncTable.tableName,
            currentOrphanIDs: Set(try SavedAssetManifestSyncTable.select(\.itemID).fetchAll(db))
                .subtracting(liveItemIDs)
        ) { ripe in
            let count = try SavedAssetManifestSyncTable.where { $0.itemID.in(ripe) }.fetchCount(db)
            try SavedAssetManifestSyncTable.where { $0.itemID.in(ripe) }.delete().execute(db)
            try ItemStorageLocalTable.where { $0.itemID.in(ripe) }.delete().execute(db)
            return count
        }
        try sweep(
            tableName: SavedArticleCaptureSyncTable.tableName,
            currentOrphanIDs: Set(try SavedArticleCaptureSyncTable.select(\.itemID).fetchAll(db))
                .subtracting(liveItemIDs)
        ) { ripe in
            let manifests = try SavedArticleCaptureSyncTable.where { $0.itemID.in(ripe) }.fetchCount(db)
            let chunks = try SavedArticleCaptureChunkSyncTable.where { $0.itemID.in(ripe) }.fetchCount(db)
            try SavedArticleCaptureChunkSyncTable.where { $0.itemID.in(ripe) }.delete().execute(db)
            try SavedArticleCaptureSyncTable.where { $0.itemID.in(ripe) }.delete().execute(db)
            return manifests + chunks
        }

        return deletedRows
    }
}

// MARK: - Dependency Key

private enum StorageMaintenanceClientKey: DependencyKey {
    static let liveValue: StorageMaintenanceClient = .noop
    static let testValue: StorageMaintenanceClient = .noop
}

extension DependencyValues {
    public var storageMaintenanceClient: StorageMaintenanceClient {
        get { self[StorageMaintenanceClientKey.self] }
        set { self[StorageMaintenanceClientKey.self] = newValue }
    }
}
