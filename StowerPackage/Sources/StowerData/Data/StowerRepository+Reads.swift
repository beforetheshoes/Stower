import Foundation
import SQLiteData

extension StowerRepository {
    static func _fetchLibrary(database: any DatabaseWriter) -> @Sendable () async throws -> [SavedItem] {
        { () async throws -> [SavedItem] in
            try await database.read { db -> [SavedItem] in
                let synced: [SavedItemSyncTable] = try SavedItemSyncTable
                    .where { !$0.isArchived }
                    .order { $0.updatedAt.desc() }
                    .fetchAll(db)

                let ids: [UUID] = synced.map(\.id)
                let locals: [SavedItemContentLocalTable] = try SavedItemContentLocalTable
                    .where { $0.itemID.in(ids) }
                    .fetchAll(db)
                let localByID: [UUID: SavedItemContentLocalTable] = Dictionary(
                    uniqueKeysWithValues: locals.map { ($0.itemID, $0) }
                )

                var seen = Set<String>()
                return synced.compactMap { row -> SavedItem? in
                    if let key = normalizedURLKey(row.canonicalURL ?? row.sourceURL) {
                        if seen.contains(key) { return nil }
                        seen.insert(key)
                    }
                    return toDomain(sync: row, local: localByID[row.id])
                }
            }
        }
    }

    static func _loadItem(database: any DatabaseWriter) -> @Sendable (UUID) async throws -> SavedItem? {
        { (id: UUID) async throws -> SavedItem? in
            try await database.read { db -> SavedItem? in
                guard let sync: SavedItemSyncTable = try SavedItemSyncTable.find(id).fetchOne(db) else { return nil }
                let local: SavedItemContentLocalTable? = try SavedItemContentLocalTable.find(id).fetchOne(db)
                return toDomain(sync: sync, local: local)
            }
        }
    }

    static func _loadReaderDocument(database: any DatabaseWriter) -> @Sendable (UUID) async throws -> ReaderDocument? {
        { (id: UUID) async throws -> ReaderDocument? in
            try await database.read { db -> ReaderDocument? in
                guard let row: SavedItemContentLocalTable = try SavedItemContentLocalTable.find(id).fetchOne(db) else { return nil }
                guard !row.documentJSON.isEmpty else { return nil }
                var document = try JSONDecoder().decode(ReaderDocument.self, from: Data(row.documentJSON.utf8))
                document.blocks = sanitizeLoadedBlocks(document.blocks)
                return document
            }
        }
    }

    static func _loadSourceHTML(database: any DatabaseWriter) -> @Sendable (UUID) async throws -> String? {
        { (id: UUID) async throws -> String? in
            try await database.read { db -> String? in
                guard let row: SavedItemContentLocalTable = try SavedItemContentLocalTable.find(id).fetchOne(db) else { return nil }
                return row.sourceHTML.isEmpty ? nil : row.sourceHTML
            }
        }
    }

    static func _deleteItem(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID) async throws -> Void {
        { (id: UUID) async throws -> Void in
            try await database.write { db -> Void in
                try SavedItemSyncTable.find(id).delete().execute(db)
            }
            scheduleSync()
        }
    }

    static func _saveReadingProgress(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, Int) async throws -> Void {
        { (id: UUID, blockIndex: Int) async throws -> Void in
            try await database.write { db -> Void in
                try SavedItemSyncTable.find(id).update {
                    $0.lastReadBlockIndex = #bind(blockIndex)
                }.execute(db)
            }
            scheduleSync()
        }
    }
}
