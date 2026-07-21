import Foundation
import SQLiteData

extension StowerRepository {
    static func _loadEditableTextSource(database: any DatabaseWriter) -> @Sendable (UUID) async throws -> EditableTextSource? {
        { id in
            try await database.read { db in
                guard let sync = try SavedItemSyncTable.find(id).fetchOne(db),
                      let local = try SavedItemContentLocalTable.find(id).fetchOne(db)
                else {
                    return nil
                }

                let text: String
                let mode: TextImportMode

                if !local.rawSourceText.isEmpty {
                    // Preferred: use the original source text that was saved during import.
                    // Always default to .auto for the editor so the preview auto-detects
                    // markdown vs plain text, regardless of what was stored. The user can
                    // still override via the Format picker.
                    text = local.rawSourceText
                    mode = .auto
                } else if !local.documentJSON.isEmpty,
                          let data = local.documentJSON.data(using: .utf8),
                          let document = try? JSONDecoder().decode(ReaderDocument.self, from: data),
                          !document.blocks.isEmpty {
                    // Fallback: reconstruct markdown from the parsed document blocks.
                    // This handles articles where rawSourceText was never saved (e.g.
                    // pre-migration items or edge cases).
                    text = ReaderDocumentMarkdownWriter.markdown(from: document)
                    mode = .markdown
                } else {
                    text = local.plainText
                    mode = .auto
                }

                return EditableTextSource(title: sync.title, text: text, mode: mode)
            }
        }
    }

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

    static func _saveSummary(
        database: any DatabaseWriter
    ) -> @Sendable (UUID, String, Int, String) async throws -> Void {
        { (id: UUID, quality: String, promptVersion: Int, text: String) async throws in
            let now = Date.now
            try await database.write { db in
                guard let content = try SavedItemContentLocalTable.find(id).fetchOne(db) else { return }
                let cacheID = "\(id.uuidString.lowercased()):\(quality)"
                try ArticleSummaryLocalTable.find(cacheID).delete().execute(db)
                try ArticleSummaryLocalTable
                    .insert {
                        ArticleSummaryLocalTable.Draft(
                            id: cacheID,
                            itemID: id,
                            quality: quality,
                            promptVersion: promptVersion,
                            contentHash: sha256Hex(content.plainText),
                            text: text,
                            generatedAt: now
                        )
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
