import Foundation
import SQLiteData

extension StowerRepository {
    static func _enqueueIngestionJob(database: any DatabaseWriter) -> @Sendable (IngestionJob.Kind, String) async throws -> Void {
        { (kind: IngestionJob.Kind, payload: String) async throws in
            try await database.write { db in
                try IngestionJobLocalTable
                    .insert {
                        IngestionJobLocalTable.Draft(
                            id: UUID(),
                            kind: kind.rawValue,
                            payload: payload,
                            createdAt: .now,
                            processedAt: nil
                        )
                    }
                    .execute(db)
            }
        }
    }

    static func _fetchPendingIngestionJobs(database: any DatabaseWriter) -> @Sendable () async throws -> [IngestionJob] {
        { () async throws -> [IngestionJob] in
            try await database.read { db -> [IngestionJob] in
                let rows: [IngestionJobLocalTable] = try IngestionJobLocalTable
                    .where { $0.processedAt.is(nil) }
                    .order { $0.createdAt }
                    .fetchAll(db)
                return rows.compactMap { row -> IngestionJob? in
                    guard let kind = IngestionJob.Kind(rawValue: row.kind) else { return nil }
                    return IngestionJob(id: row.id, kind: kind, payload: row.payload, createdAt: row.createdAt)
                }
            }
        }
    }

    static func _markIngestionJobProcessed(database: any DatabaseWriter) -> @Sendable (UUID) async throws -> Void {
        { (id: UUID) async throws in
            try await database.write { db in
                try IngestionJobLocalTable
                    .find(id)
                    .update {
                        $0.processedAt = #bind(Date.now as Date?)
                    }
                    .execute(db)
            }
        }
    }

    /// Hydrates the local content table for PDF items on devices that received
    /// them via CloudKit sync. Unlike URL items (which rehydrate by re-fetching
    /// the source URL through `enqueueHydrationJobsForMissingContent`), PDFs
    /// carry their extracted text in a dedicated CloudKit-synced table so the
    /// second device can render the structured-text view without the raw PDF
    /// bytes (which never sync). This walks rows in `SavedPDFContentSyncTable`
    /// whose matching `SavedItemContentLocalTable` row is missing or empty
    /// and copies the extracted `documentJSON`/`plainText` across.
    static func _hydratePDFItemsFromSyncedContent(database: any DatabaseWriter) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            let now = Date.now
            return try await database.write { db -> Int in
                let pdfRows: [SavedPDFContentSyncTable] = try SavedPDFContentSyncTable.fetchAll(db)
                var hydrated = 0
                for pdfRow in pdfRows {
                    let existing: SavedItemContentLocalTable? = try SavedItemContentLocalTable
                        .find(pdfRow.id)
                        .fetchOne(db)

                    // Only populate when there is nothing to render — we do
                    // not clobber a device's locally-ingested copy if it
                    // already has one.
                    if let existing, !existing.documentJSON.isEmpty {
                        continue
                    }

                    if existing != nil {
                        try SavedItemContentLocalTable
                            .find(pdfRow.id)
                            .update {
                                $0.renderFormat = RenderFormat.pdf.rawValue
                                $0.documentVersion = 1
                                $0.plainText = pdfRow.plainText
                                $0.documentJSON = pdfRow.documentJSON
                                $0.localStatus = "available"
                                $0.localError = nil as String?
                                $0.updatedAt = now
                            }
                            .execute(db)
                    } else {
                        try SavedItemContentLocalTable
                            .insert {
                                SavedItemContentLocalTable.Draft(
                                    itemID: pdfRow.id,
                                    renderFormat: RenderFormat.pdf.rawValue,
                                    documentVersion: 1,
                                    plainText: pdfRow.plainText,
                                    documentJSON: pdfRow.documentJSON,
                                    sourceHTMLHash: "",
                                    sourceHTML: "",
                                    localStatus: "available",
                                    localError: nil,
                                    createdAt: now,
                                    updatedAt: now
                                )
                            }
                            .execute(db)
                    }
                    hydrated += 1
                }
                return hydrated
            }
        }
    }

    static func _enqueueHydrationJobsForMissingContent(database: any DatabaseWriter) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            let now = Date.now
            return try await database.write { db -> Int in
                let synced: [SavedItemSyncTable] = try SavedItemSyncTable
                    .where { !$0.isArchived }
                    .fetchAll(db)
                let locals: [SavedItemContentLocalTable] = try SavedItemContentLocalTable.fetchAll(db)
                let localIDs: Set<UUID> = Set(locals.map(\.itemID))

                var enqueued = 0
                for item in synced {
                    guard !localIDs.contains(item.id) else { continue }
                    guard let url = item.sourceURL, !url.isEmpty else { continue }

                    try SavedItemContentLocalTable
                        .insert {
                            SavedItemContentLocalTable.Draft(
                                itemID: item.id,
                                renderFormat: "structuredV1",
                                documentVersion: 1,
                                plainText: "",
                                documentJSON: "",
                                sourceHTMLHash: "",
                                sourceHTML: "",
                                localStatus: "notDownloaded",
                                localError: nil,
                                createdAt: now,
                                updatedAt: now
                            )
                        }
                        .execute(db)

                    let payload = try String(
                        bytes: JSONEncoder().encode(HydrationPayload(itemID: item.id, url: url)),
                        encoding: .utf8
                    ) ?? ""
                    try IngestionJobLocalTable
                        .insert {
                            IngestionJobLocalTable.Draft(
                                id: UUID(),
                                kind: IngestionJob.Kind.hydrate.rawValue,
                                payload: payload,
                                createdAt: now,
                                processedAt: nil
                            )
                        }
                        .execute(db)
                    enqueued += 1
                }
                return enqueued
            }
        }
    }
}
