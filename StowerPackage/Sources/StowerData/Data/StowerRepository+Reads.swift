import Foundation
import SQLiteData

extension StowerRepository {
    // `_fetchLibrary()` has been replaced by `_fetchLibraryFiltered(_:)` in
    // StowerRepository+Filters.swift — every caller now routes through a
    // `LibraryFilter` so the repository can push the filter into SQL.

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

    static func _loadSummary(
        database: any DatabaseWriter
    ) -> @Sendable (UUID, String, Int) async throws -> CachedSummary? {
        { (id: UUID, quality: String, promptVersion: Int) async throws -> CachedSummary? in
            try await database.read { db -> CachedSummary? in
                guard let content = try SavedItemContentLocalTable.find(id).fetchOne(db) else { return nil }
                let cacheID = "\(id.uuidString.lowercased()):\(quality)"
                guard let row = try ArticleSummaryLocalTable.find(cacheID).fetchOne(db),
                      row.promptVersion == promptVersion,
                      row.contentHash == sha256Hex(content.plainText),
                      !row.text.isEmpty
                else {
                    return nil
                }
                return CachedSummary(
                    text: row.text,
                    generatedAt: row.generatedAt,
                    quality: row.quality,
                    promptVersion: row.promptVersion
                )
            }
        }
    }

    // The old `_deleteItem` hard-delete has been replaced by the soft-delete
    // path in StowerRepository+Filters.swift (`_softDeleteItem`). The public
    // `deleteItem` closure on the repository struct now routes to that
    // soft-delete implementation so existing call sites get trash behavior
    // for free. Use `permanentlyDelete` for the old hard-delete semantics.

    static func _saveReadingProgress(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, Int) async throws -> Void {
        { (id: UUID, blockIndex: Int) async throws in
            try await database.write { db in
                try SavedItemSyncTable
                    .find(id)
                    .update {
                        $0.lastReadBlockIndex = #bind(blockIndex)
                    }
                    .execute(db)
            }
            scheduleSync()
        }
    }
}
