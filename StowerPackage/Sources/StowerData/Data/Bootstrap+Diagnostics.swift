import Foundation
import SQLiteData

extension StowerDatabase {
    static func makeDiagnosticsLoad(database: any DatabaseWriter) -> @Sendable () async throws -> SyncDiagnostics {
        { () async throws -> SyncDiagnostics in
            try await database.read { db -> SyncDiagnostics in
                let syncedCount: Int = try SavedItemSyncTable.fetchCount(db)
                let tagCount: Int = try TagSyncTable.fetchCount(db)
                let itemTagCount: Int = try ItemTagSyncTable.fetchCount(db)
                let sample: [SyncItemSummary] = try SavedItemSyncTable
                    .order { $0.updatedAt.desc() }
                    .fetchAll(db)
                    .prefix(5)
                    .map { SyncItemSummary(id: $0.id, title: $0.title, sourceURL: $0.sourceURL) }

                let pendingCount: Int = try Int.fetchOne(
                    db,
                    sql: #"SELECT COUNT(*) FROM "sqlitedata_icloud"."sqlitedata_icloud_pendingRecordZoneChanges""#
                ) ?? 0

                let metadataCount: Int = try Int.fetchOne(
                    db,
                    sql: #"SELECT COUNT(*) FROM "sqlitedata_icloud"."sqlitedata_icloud_metadata""#
                ) ?? 0

                return SyncDiagnostics(
                    syncedItemsCount: syncedCount,
                    pendingChangesCount: pendingCount,
                    metadataCount: metadataCount,
                    syncedTagsCount: tagCount,
                    syncedItemTagsCount: itemTagCount,
                    sampleItems: Array(sample)
                )
            }
        }
    }
}
