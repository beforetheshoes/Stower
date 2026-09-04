import Foundation
import SQLiteData

// MARK: - Filter-aware reads + list-bucket mutations

extension StowerRepository {
    // MARK: Filtered fetch

    static func _fetchLibraryFiltered(
        database: any DatabaseWriter
    ) -> @Sendable (LibraryFilter) async throws -> [SavedItem] {
        { (filter: LibraryFilter) async throws -> [SavedItem] in
            try await database.read { db -> [SavedItem] in
                try LibraryQueries.fetchItems(db, filter: filter, query: "", oldestFirst: false)
            }
        }
    }

    // MARK: Mutations

    static func _setReadStatus(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, Bool) async throws -> Void {
        { (id: UUID, isRead: Bool) async throws in
            let now = Date.now
            try await database.write { db in
                try SavedItemSyncTable
                    .find(id)
                    .update {
                        $0.isRead = #bind(isRead)
                        $0.updatedAt = #bind(now)
                    }
                    .execute(db)
            }
            scheduleSync()
        }
    }

    static func _setStarred(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, Bool) async throws -> Void {
        { (id: UUID, isStarred: Bool) async throws in
            let now = Date.now
            try await database.write { db in
                try SavedItemSyncTable
                    .find(id)
                    .update {
                        $0.isStarred = #bind(isStarred)
                        $0.updatedAt = #bind(now)
                    }
                    .execute(db)
            }
            scheduleSync()
        }
    }

    static func _softDeleteItem(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID) async throws -> Void {
        { (id: UUID) async throws in
            let now = Date.now
            try await database.write { db in
                try SavedItemSyncTable
                    .find(id)
                    .update {
                        $0.deletedAt = #bind(Date?.some(now))
                        $0.updatedAt = #bind(now)
                    }
                    .execute(db)
            }
            scheduleSync()
        }
    }

    static func _restoreFromTrash(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID) async throws -> Void {
        { (id: UUID) async throws in
            let now = Date.now
            try await database.write { db in
                try SavedItemSyncTable
                    .find(id)
                    .update {
                        $0.deletedAt = #bind(nil)
                        $0.updatedAt = #bind(now)
                    }
                    .execute(db)
            }
            scheduleSync()
        }
    }

    static func _permanentlyDelete(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID) async throws -> Void {
        { (id: UUID) async throws in
            try await database.write { db in
                try ItemTagSyncTable.where { $0.itemID.eq(id) }.delete().execute(db)
                try SavedArticleCaptureChunkSyncTable.where { $0.itemID.eq(id) }.delete().execute(db)
                try SavedArticleCaptureSyncTable.where { $0.itemID.eq(id) }.delete().execute(db)
                // Content sync tables key their `id` on the item's ID and have no
                // foreign keys, so they must be deleted explicitly or their rows
                // (including multi-hundred-MB website zips) outlive the item in
                // both the local database and CloudKit.
                try SavedWebsiteArchiveSyncTable.find(id).delete().execute(db)
                try SavedPDFContentSyncTable.find(id).delete().execute(db)
                try SavedTextContentSyncTable.find(id).delete().execute(db)
                try SavedAssetManifestSyncTable.where { $0.itemID.eq(id) }.delete().execute(db)
                try ItemStorageLocalTable.find(id).delete().execute(db)
                try SavedItemSyncTable.find(id).delete().execute(db)
            }
            scheduleSync()
        }
    }

    /// Deletes trash items older than the 30-day retention window.
    /// Returns the IDs that were purged so callers can clean up on-disk assets.
    static func _purgeOldTrash(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable () async throws -> [UUID] {
        {
            let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
            let purged: [UUID] = try await database.write { db -> [UUID] in
                // Do the filter in-memory — expressing `"deletedAt" < cutoff`
                // in StructuredQueries is fussy because deletedAt is Date?.
                // The trash bucket is small so the overhead is negligible.
                let trashed: [SavedItemSyncTable] = try SavedItemSyncTable
                    .where { $0.deletedAt.isNot(nil) }
                    .fetchAll(db)
                let expired = trashed.filter { ($0.deletedAt ?? .distantFuture) < cutoff }
                let ids = expired.map(\.id)
                if !ids.isEmpty {
                    try ItemTagSyncTable.where { $0.itemID.in(ids) }.delete().execute(db)
                    try SavedArticleCaptureChunkSyncTable.where { $0.itemID.in(ids) }.delete().execute(db)
                    try SavedArticleCaptureSyncTable.where { $0.itemID.in(ids) }.delete().execute(db)
                    // See _permanentlyDelete: content sync tables have no foreign
                    // keys and must be cleared explicitly to avoid orphaned blobs.
                    try SavedWebsiteArchiveSyncTable.where { $0.id.in(ids) }.delete().execute(db)
                    try SavedPDFContentSyncTable.where { $0.id.in(ids) }.delete().execute(db)
                    try SavedTextContentSyncTable.where { $0.id.in(ids) }.delete().execute(db)
                    try SavedAssetManifestSyncTable.where { $0.itemID.in(ids) }.delete().execute(db)
                    try ItemStorageLocalTable.where { $0.itemID.in(ids) }.delete().execute(db)
                    try SavedItemSyncTable.where { $0.id.in(ids) }.delete().execute(db)
                }
                return ids
            }
            if !purged.isEmpty {
                scheduleSync()
            }
            return purged
        }
    }

    // MARK: List counts

    static func _fetchListCounts(
        database: any DatabaseWriter
    ) -> @Sendable () async throws -> LibraryListCounts {
        {
            try await database.read { db -> LibraryListCounts in
                try LibraryQueries.fetchListCounts(db)
            }
        }
    }
}
