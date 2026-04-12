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
                let synced: [SavedItemSyncTable]
                switch filter {
                case .all:
                    synced = try SavedItemSyncTable
                        .where { $0.deletedAt.is(nil) }
                        .order { $0.updatedAt.desc() }
                        .fetchAll(db)

                case .unread:
                    synced = try SavedItemSyncTable
                        .where { $0.deletedAt.is(nil) && !$0.isRead }
                        .order { $0.updatedAt.desc() }
                        .fetchAll(db)

                case .read:
                    synced = try SavedItemSyncTable
                        .where { $0.deletedAt.is(nil) && $0.isRead }
                        .order { $0.updatedAt.desc() }
                        .fetchAll(db)

                case .starred:
                    synced = try SavedItemSyncTable
                        .where { $0.deletedAt.is(nil) && $0.isStarred }
                        .order { $0.updatedAt.desc() }
                        .fetchAll(db)

                case .recentlyDeleted:
                    synced = try SavedItemSyncTable
                        .where { $0.deletedAt.isNot(nil) }
                        .order { $0.updatedAt.desc() }
                        .fetchAll(db)

                case .untagged:
                    // Two-step: (1) IDs of items that have any tag, (2) NOT IN.
                    let taggedRows: [ItemTagSyncTable] = try ItemTagSyncTable.all.fetchAll(db)
                    let taggedIDs: [UUID] = Array(Set(taggedRows.map(\.itemID)))
                    synced = try SavedItemSyncTable
                        .where { $0.deletedAt.is(nil) && !$0.id.in(taggedIDs) }
                        .order { $0.updatedAt.desc() }
                        .fetchAll(db)

                case .tag(let tagID):
                    let junction: [ItemTagSyncTable] = try ItemTagSyncTable
                        .where { $0.tagID.eq(tagID) }
                        .fetchAll(db)
                    let itemIDs: [UUID] = junction.map(\.itemID)
                    if itemIDs.isEmpty {
                        synced = []
                    } else {
                        synced = try SavedItemSyncTable
                            .where { $0.deletedAt.is(nil) && $0.id.in(itemIDs) }
                            .order { $0.updatedAt.desc() }
                            .fetchAll(db)
                    }
                }

                let ids: [UUID] = synced.map(\.id)

                let locals: [SavedItemContentLocalTable] = ids.isEmpty
                    ? []
                    : try SavedItemContentLocalTable
                        .where { $0.itemID.in(ids) }
                        .fetchAll(db)
                let localByID: [UUID: SavedItemContentLocalTable] = Dictionary(
                    uniqueKeysWithValues: locals.map { ($0.itemID, $0) }
                )

                // Batch-load junction rows for every item in the result set.
                let junctions: [ItemTagSyncTable] = ids.isEmpty
                    ? []
                    : try ItemTagSyncTable.where { $0.itemID.in(ids) }.fetchAll(db)
                var tagIDsByItem: [UUID: [UUID]] = [:] // swiftlint:disable:this prefer_let_over_var
                for row in junctions {
                    tagIDsByItem[row.itemID, default: []].append(row.tagID)
                }

                var seen = Set<String>()
                return synced.compactMap { row -> SavedItem? in
                    if let key = normalizedURLKey(row.canonicalURL ?? row.sourceURL) {
                        if seen.contains(key) {
                            return nil
                        }
                        seen.insert(key)
                    }
                    return toDomain(
                        sync: row,
                        local: localByID[row.id],
                        tagIDs: tagIDsByItem[row.id] ?? []
                    )
                }
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
                let allCount = try SavedItemSyncTable
                    .where { $0.deletedAt.is(nil) }
                    .fetchCount(db)
                let unreadCount = try SavedItemSyncTable
                    .where { $0.deletedAt.is(nil) && !$0.isRead }
                    .fetchCount(db)
                let readCount = try SavedItemSyncTable
                    .where { $0.deletedAt.is(nil) && $0.isRead }
                    .fetchCount(db)
                let starredCount = try SavedItemSyncTable
                    .where { $0.deletedAt.is(nil) && $0.isStarred }
                    .fetchCount(db)
                let trashCount = try SavedItemSyncTable
                    .where { $0.deletedAt.isNot(nil) }
                    .fetchCount(db)

                // Untagged: live items whose IDs don't appear in the junction.
                let taggedRows: [ItemTagSyncTable] = try ItemTagSyncTable.all.fetchAll(db)
                let taggedIDs: [UUID] = Array(Set(taggedRows.map(\.itemID)))
                let untaggedCount = try SavedItemSyncTable
                    .where { $0.deletedAt.is(nil) && !$0.id.in(taggedIDs) }
                    .fetchCount(db)

                // Per-tag counts: only count live (non-deleted) items.
                let liveIDs: [UUID] = try SavedItemSyncTable
                    .where { $0.deletedAt.is(nil) }
                    .fetchAll(db)
                    .map(\.id)
                let liveIDSet = Set(liveIDs)
                var byTag: [UUID: Int] = [:] // swiftlint:disable:this prefer_let_over_var
                for row in taggedRows where liveIDSet.contains(row.itemID) {
                    byTag[row.tagID, default: 0] += 1
                }

                return LibraryListCounts(
                    unread: unreadCount,
                    read: readCount,
                    starred: starredCount,
                    untagged: untaggedCount,
                    all: allCount,
                    recentlyDeleted: trashCount,
                    byTag: byTag
                )
            }
        }
    }
}
