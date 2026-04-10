import Foundation
import SQLiteData

extension StowerRepository {
    static func _saveReaderDocument(database: any DatabaseWriter) -> @Sendable (UUID, ReaderDocument, String) async throws -> Void {
        { (id: UUID, document: ReaderDocument, plainText: String) async throws -> Void in
            let now: Date = Date.now
            let json: String = try String(decoding: JSONEncoder().encode(document), as: UTF8.self)
            let hash: String = sha256Hex(plainText)
            try await database.write { db -> Void in
                guard try SavedItemSyncTable.find(id).fetchOne(db) != nil else { return }
                if try SavedItemContentLocalTable.find(id).fetchOne(db) != nil {
                    try SavedItemContentLocalTable.find(id).update {
                        $0.documentJSON = json
                        $0.plainText = plainText
                        $0.sourceHTMLHash = hash
                        $0.localStatus = "available"
                        $0.localError = #bind(nil as String?)
                        $0.updatedAt = now
                    }.execute(db)
                } else {
                    try SavedItemContentLocalTable.insert {
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
                    }.execute(db)
                }
            }
        }
    }

    static func _upsertMedia(database: any DatabaseWriter) -> @Sendable ([MediaDescriptor], UUID) async throws -> Void {
        { (media: [MediaDescriptor], itemID: UUID) async throws -> Void in
            let now: Date = Date.now
            try await database.write { db -> Void in
                try SavedMediaLocalTable.where { $0.itemID.eq(itemID) }.delete().execute(db)
                for descriptor in media {
                    try SavedMediaLocalTable.insert {
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
                    }.execute(db)
                }
            }
        }
    }
}
