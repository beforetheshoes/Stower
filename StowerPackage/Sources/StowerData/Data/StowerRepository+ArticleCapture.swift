import Foundation
import SQLiteData

extension StowerRepository {
    static func _saveArticleCapture(
        database: any DatabaseWriter,
        scheduleSync: @escaping @Sendable () -> Void
    ) -> @Sendable (WebCaptureManifest, [WebCaptureChunk]) async throws -> Void {
        { manifest, chunks in
            guard chunks.count == manifest.chunkCount,
                  chunks.reduce(0, { $0 + $1.data.count }) == manifest.byteCount
            else {
                throw ArticleCaptureRepositoryError.incompleteChunkSet
            }

            let now = Date.now
            try await database.write { db in
                // The manifest is only published after every replacement chunk
                // is present in the same transaction.
                try SavedArticleCaptureChunkSyncTable
                    .where { $0.itemID.eq(manifest.itemID) }
                    .delete()
                    .execute(db)
                try SavedArticleCaptureSyncTable
                    .where { $0.itemID.eq(manifest.itemID) }
                    .delete()
                    .execute(db)

                for chunk in chunks {
                    try SavedArticleCaptureChunkSyncTable.insert {
                        SavedArticleCaptureChunkSyncTable.Draft(
                            id: chunk.id,
                            itemID: manifest.itemID,
                            captureID: manifest.captureID,
                            sequence: chunk.sequence,
                            data: chunk.data,
                            byteCount: chunk.data.count,
                            sha256: chunk.sha256,
                            createdAt: now
                        )
                    }
                    .execute(db)
                }
                try SavedArticleCaptureSyncTable.insert {
                    SavedArticleCaptureSyncTable.Draft(
                        id: manifest.itemID,
                        itemID: manifest.itemID,
                        captureID: manifest.captureID,
                        version: manifest.version,
                        sha256: manifest.sha256,
                        byteCount: manifest.byteCount,
                        chunkCount: manifest.chunkCount,
                        capturedAt: manifest.capturedAt,
                        updatedAt: now
                    )
                }
                .execute(db)
            }
            scheduleSync()
        }
    }

    static func _loadArticleCapture(
        database: any DatabaseWriter
    ) -> @Sendable (UUID) async throws -> SyncedWebCapture? {
        { itemID in
            try await database.read { db -> SyncedWebCapture? in
                guard let row = try SavedArticleCaptureSyncTable
                    .where({ $0.itemID.eq(itemID) })
                    .fetchOne(db)
                else { return nil }

                let chunkRows = try SavedArticleCaptureChunkSyncTable
                    .where { $0.captureID.eq(row.captureID) }
                    .fetchAll(db)
                    .sorted { $0.sequence < $1.sequence }
                let manifest = WebCaptureManifest(
                    itemID: row.itemID,
                    captureID: row.captureID,
                    sha256: row.sha256,
                    byteCount: row.byteCount,
                    chunkCount: row.chunkCount,
                    version: row.version,
                    capturedAt: row.capturedAt
                )
                let chunks = chunkRows.map {
                    WebCaptureChunk(sequence: $0.sequence, data: $0.data, sha256: $0.sha256, id: $0.id)
                }
                return SyncedWebCapture(manifest: manifest, chunks: chunks)
            }
        }
    }

    static func _markArticleCaptureInstalled(
        database: any DatabaseWriter
    ) -> @Sendable (UUID, UUID, Int) async throws -> Void {
        { itemID, captureID, version in
            try await database.write { db in
                guard try SavedItemContentLocalTable.find(itemID).fetchOne(db) != nil else { return }
                try SavedItemContentLocalTable
                    .find(itemID)
                    .update {
                        $0.captureID = #bind(captureID)
                        $0.captureVersion = version
                        $0.updatedAt = Date.now
                    }
                    .execute(db)
            }
        }
    }
}

public enum ArticleCaptureRepositoryError: Error, Equatable {
    case incompleteChunkSet
}
