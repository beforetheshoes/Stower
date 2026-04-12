import Foundation
import SQLiteData

extension StowerRepository {
    static func _saveReaderDocument(database: any DatabaseWriter) -> @Sendable (UUID, ReaderDocument, String) async throws -> Void {
        { (id: UUID, document: ReaderDocument, plainText: String) async throws in
            let now = Date.now
            let json = try String(bytes: JSONEncoder().encode(document), encoding: .utf8) ?? ""
            let hash = sha256Hex(plainText)
            try await database.write { db in
                guard try SavedItemSyncTable.find(id).fetchOne(db) != nil else { return }
                if try SavedItemContentLocalTable.find(id).fetchOne(db) != nil {
                    try SavedItemContentLocalTable
                        .find(id)
                        .update {
                            $0.documentJSON = json
                            $0.plainText = plainText
                            $0.sourceHTMLHash = hash
                            $0.localStatus = "available"
                            $0.localError = #bind(nil as String?)
                            $0.updatedAt = now
                        }
                        .execute(db)
                } else {
                    try SavedItemContentLocalTable
                        .insert {
                            SavedItemContentLocalTable.Draft(
                                itemID: id,
                                renderFormat: document.sourceURL == nil ? "plainText" : "structuredV1",
                                documentVersion: document.version,
                                plainText: plainText,
                                documentJSON: json,
                                sourceHTMLHash: hash,
                                sourceHTML: "",
                                localStatus: "available",
                                localError: nil,
                                createdAt: now,
                                updatedAt: now
                            )
                        }
                        .execute(db)
                }
            }
        }
    }

    static func _saveSummary(database: any DatabaseWriter) -> @Sendable (UUID, String) async throws -> Void {
        { (id: UUID, text: String) async throws in
            let now = Date.now
            try await database.write { db in
                // The content row is created during ingestion; if it's missing
                // we silently drop the write rather than synthesizing a half-
                // populated row. A missing row means the item itself isn't
                // persisted, which is an upstream bug the summary cache can't fix.
                guard try SavedItemContentLocalTable.find(id).fetchOne(db) != nil else { return }
                try SavedItemContentLocalTable
                    .find(id)
                    .update {
                        $0.summary = #bind(text)
                        $0.summaryGeneratedAt = #bind(now)
                        $0.updatedAt = now
                    }
                    .execute(db)
            }
        }
    }

    static func _upsertMedia(database: any DatabaseWriter) -> @Sendable ([MediaDescriptor], UUID) async throws -> Void {
        { (media: [MediaDescriptor], itemID: UUID) async throws in
            let now = Date.now
            try await database.write { db in
                try SavedMediaLocalTable.where { $0.itemID.eq(itemID) }.delete().execute(db)
                for descriptor in media {
                    try SavedMediaLocalTable
                        .insert {
                            SavedMediaLocalTable.Draft(
                                id: UUID(),
                                itemID: itemID,
                                kind: descriptor.kind.rawValue,
                                sourceURL: descriptor.sourceURL,
                                localURL: descriptor.localURL,
                                mimeType: descriptor.mimeType,
                                width: descriptor.width,
                                height: descriptor.height,
                                durationSeconds: descriptor.durationSeconds,
                                posterURL: descriptor.posterURL,
                                caption: descriptor.caption,
                                status: "ready",
                                createdAt: now,
                                updatedAt: now
                            )
                        }
                        .execute(db)
                }
            }
        }
    }
}
