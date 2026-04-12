import CryptoKit
import Foundation
import SQLiteData

extension StowerRepository {
    /// Maps an `IngestionResult.processingState` to the string value stored
    /// in `savedItemContentLocalTables.localStatus`. Previously all call
    /// sites hardcoded `"available"`, which meant a parse that came back
    /// with zero content still got persisted as "ready to read" — leaving
    /// the reader on a blank screen for anything that couldn't be extracted.
    private static func localStatus(for state: ProcessingState) -> String {
        switch state {
        case .ready, .partial:
            return "available"
        case .failed:
            return "failed"
        case .extracting:
            return "downloading"
        case .queued:
            return "notDownloaded"
        }
    }

    static func _createItemFromIngestion(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (IngestionResult) async throws -> SavedItem {
        { (result: IngestionResult) async throws -> SavedItem in
            let item: SavedItem = try await database.write { db -> SavedItem in
                let now = Date.now
                let itemID = stableItemID(from: result.canonicalURL ?? result.sourceURL)
                let syncDraft = makeSyncDraft(id: itemID, result: result, now: now)
                try SavedItemSyncTable.upsert { syncDraft }.execute(db)
                try persistLocalContentAndCaches(db: db, itemID: itemID, result: result, now: now, updateLocalStatus: localStatus(for: result.processingState))
                // Read back the just-written local row so the returned
                // SavedItem carries the correct processingState (.ready)
                // instead of defaulting to .queued from a nil local. Without
                // this, the library card stays on "Queued" until the
                // sidebar re-queries the DB.
                let local = try SavedItemContentLocalTable.find(itemID).fetchOne(db)
                return toDomain(from: syncDraft, local: local, inferredContent: result.plainText)
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
            let now = Date.now
            try await database.write { db in
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
                        now.timeIntervalSince1970, id.uuidString,
                    ]
                )
                try persistLocalContentAndCaches(db: db, itemID: id, result: result, now: now, updateLocalStatus: localStatus(for: result.processingState))
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
        { (id: UUID, result: IngestionResult) async throws in
            let now = Date.now
            try await database.write { db in
                guard try SavedItemSyncTable.find(id).fetchOne(db) != nil else { return }
                try persistLocalContentAndCaches(db: db, itemID: id, result: result, now: now, updateLocalStatus: localStatus(for: result.processingState))
            }
        }
    }

    static func _updateLocalContentStatus(database: any DatabaseWriter) -> @Sendable (UUID, String, String?) async throws -> Void {
        { (id: UUID, status: String, message: String?) async throws in
            let now = Date.now
            try await database.write { db in
                guard try SavedItemContentLocalTable.find(id).fetchOne(db) != nil else { return }
                try SavedItemContentLocalTable
                    .find(id)
                    .update {
                        $0.localStatus = status
                        $0.localError = #bind(message)
                        $0.updatedAt = now
                    }
                    .execute(db)
            }
        }
    }
}
