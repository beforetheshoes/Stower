import CryptoKit
import Foundation
import SQLiteData

extension StowerRepository {
    static func _createItemFromIngestion(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (IngestionResult) async throws -> SavedItem {
        { (result: IngestionResult) async throws -> SavedItem in
            let item: SavedItem = try await database.write { db -> SavedItem in
                let now: Date = Date.now
                let itemID: UUID = stableItemID(from: result.canonicalURL ?? result.sourceURL)
                let syncDraft: SavedItemSyncTable.Draft = makeSyncDraft(id: itemID, result: result, now: now)
                try SavedItemSyncTable.upsert { syncDraft }.execute(db)
                try persistLocalContentAndCaches(db: db, itemID: itemID, result: result, now: now, updateLocalStatus: "available")
                return toDomain(from: syncDraft, local: nil, inferredContent: result.plainText)
            }
            scheduleSync()
            return item
        }
    }

    static func _updateItemFromIngestion(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (UUID, IngestionResult) async throws -> SavedItem? {
        { (id: UUID, result: IngestionResult) async throws -> SavedItem? in
            let now: Date = Date.now
            try await database.write { db -> Void in
                guard try SavedItemSyncTable.find(id).fetchOne(db) != nil else { return }
                try db.execute(
                    sql: """
                        UPDATE "savedItemSyncTables"
                        SET title=?, sourceURL=?, canonicalURL=?, excerpt=?, heroImageURL=?,
                            author=?, publishedAt=?, siteName=?, readingTimeMinutes=?,
                            hasRichMedia=?, updatedAt=?
                        WHERE id=?
                        """,
                    arguments: [
                        result.title, result.sourceURL, result.canonicalURL, result.excerpt,
                        result.heroImageURL, result.author, result.publishedAt?.timeIntervalSince1970,
                        result.siteName, result.readingTimeMinutes, result.hasRichMedia ? 1 : 0,
                        now.timeIntervalSince1970, id.uuidString
                    ]
                )
                try SavedMediaLocalTable.where { $0.itemID.eq(id) }.delete().execute(db)
                try SavedEmbedLocalTable.where { $0.itemID.eq(id) }.delete().execute(db)
                try persistLocalContentAndCaches(db: db, itemID: id, result: result, now: now, updateLocalStatus: "available")
            }
            scheduleSync()
            return try await database.read { db -> SavedItem? in
                guard let sync: SavedItemSyncTable = try SavedItemSyncTable.find(id).fetchOne(db) else { return nil }
                let local: SavedItemContentLocalTable? = try SavedItemContentLocalTable.find(id).fetchOne(db)
                return toDomain(sync: sync, local: local)
            }
        }
    }

    static func _hydrateItemContent(database: any DatabaseWriter) -> @Sendable (UUID, IngestionResult) async throws -> Void {
        { (id: UUID, result: IngestionResult) async throws -> Void in
            let now: Date = Date.now
            try await database.write { db -> Void in
                guard try SavedItemSyncTable.find(id).fetchOne(db) != nil else { return }
                try SavedMediaLocalTable.where { $0.itemID.eq(id) }.delete().execute(db)
                try SavedEmbedLocalTable.where { $0.itemID.eq(id) }.delete().execute(db)
                try persistLocalContentAndCaches(db: db, itemID: id, result: result, now: now, updateLocalStatus: "available")
            }
        }
    }

    static func _updateLocalContentStatus(database: any DatabaseWriter) -> @Sendable (UUID, String, String?) async throws -> Void {
        { (id: UUID, status: String, message: String?) async throws -> Void in
            let now: Date = Date.now
            try await database.write { db -> Void in
                guard try SavedItemContentLocalTable.find(id).fetchOne(db) != nil else { return }
                try SavedItemContentLocalTable.find(id).update {
                    $0.localStatus = status
                    $0.localError = #bind(message)
                    $0.updatedAt = now
                }.execute(db)
            }
        }
    }
}
