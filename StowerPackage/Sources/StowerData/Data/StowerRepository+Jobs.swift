import Dependencies
import Foundation
import SQLiteData

extension StowerRepository {
    static func _enqueueIngestionJob(database: any DatabaseWriter) -> @Sendable (IngestionJob.Kind, String) async throws -> Void {
        { (kind: IngestionJob.Kind, payload: String) async throws in
            @Dependency(\.date.now)
            var now
            @Dependency(\.uuid)
            var uuid
            try await database.write { db in
                if kind.isHydrationJob {
                    let existing = try IngestionJobLocalTable
                        .where { $0.kind.eq(kind.rawValue) }
                        .where { $0.payload.eq(payload) }
                        .where { $0.processedAt.is(nil) }
                        .fetchCount(db)
                    guard existing == 0 else { return }
                }
                try IngestionJobLocalTable
                    .insert {
                        IngestionJobLocalTable.Draft(
                            id: uuid(),
                            kind: kind.rawValue,
                            payload: payload,
                            createdAt: now,
                            processedAt: nil
                        )
                    }
                    .execute(db)
            }
        }
    }

    static func _claimNextIngestionJob(
        database: any DatabaseWriter
    ) -> @Sendable (Date) async throws -> IngestionJob? {
        { now in
            try await database.write { db in
                let staleBefore = now.addingTimeInterval(-600)
                try IngestionJobLocalTable
                    .where { $0.status.eq(IngestionJob.Status.processing.rawValue) }
                    .where { $0.claimedAt < #bind(staleBefore as Date?) }
                    .where { $0.attemptCount < 3 }
                    .update {
                        $0.status = IngestionJob.Status.queued.rawValue
                        $0.claimedAt = nil as Date?
                    }
                    .execute(db)

                try IngestionJobLocalTable
                    .where { $0.status.eq(IngestionJob.Status.processing.rawValue) }
                    .where { $0.claimedAt < #bind(staleBefore as Date?) }
                    .where { $0.attemptCount >= 3 }
                    .update {
                        $0.status = IngestionJob.Status.failed.rawValue
                        $0.claimedAt = nil as Date?
                        $0.lastError = #bind("Import interrupted before it could finish." as String?)
                    }
                    .execute(db)

                let nextJob = IngestionJobLocalTable
                    .where { $0.status.eq(IngestionJob.Status.queued.rawValue) }
                    .where { $0.attemptCount < 3 }
                    .order { $0.createdAt }
                guard let row = try nextJob.fetchOne(db) else { return nil }

                try IngestionJobLocalTable
                    .find(row.id)
                    .update {
                        $0.status = IngestionJob.Status.processing.rawValue
                        $0.claimedAt = #bind(now as Date?)
                        $0.attemptCount += 1
                        $0.lastError = nil as String?
                    }
                    .execute(db)

                var claimed = row
                claimed.status = IngestionJob.Status.processing.rawValue
                claimed.claimedAt = now
                claimed.attemptCount += 1
                claimed.lastError = nil
                return ingestionJob(from: claimed)
            }
        }
    }

    static func _claimNextIngestionJobOfKind(
        database: any DatabaseWriter
    ) -> @Sendable (IngestionJob.Kind, Date) async throws -> IngestionJob? {
        { kind, now in
            try await database.write { db in
                let staleBefore = now.addingTimeInterval(-600)
                try IngestionJobLocalTable
                    .where { $0.kind.eq(kind.rawValue) }
                    .where { $0.status.eq(IngestionJob.Status.processing.rawValue) }
                    .where { $0.claimedAt < #bind(staleBefore as Date?) }
                    .where { $0.attemptCount < 3 }
                    .update {
                        $0.status = IngestionJob.Status.queued.rawValue
                        $0.claimedAt = nil as Date?
                    }
                    .execute(db)

                try IngestionJobLocalTable
                    .where { $0.kind.eq(kind.rawValue) }
                    .where { $0.status.eq(IngestionJob.Status.processing.rawValue) }
                    .where { $0.claimedAt < #bind(staleBefore as Date?) }
                    .where { $0.attemptCount >= 3 }
                    .update {
                        $0.status = IngestionJob.Status.failed.rawValue
                        $0.claimedAt = nil as Date?
                        $0.lastError = #bind("Import interrupted before it could finish." as String?)
                    }
                    .execute(db)

                let nextJob = IngestionJobLocalTable
                    .where { $0.kind.eq(kind.rawValue) }
                    .where { $0.status.eq(IngestionJob.Status.queued.rawValue) }
                    .where { $0.attemptCount < 3 }
                    .order { $0.createdAt }
                guard let row = try nextJob.fetchOne(db) else { return nil }

                try IngestionJobLocalTable
                    .find(row.id)
                    .update {
                        $0.status = IngestionJob.Status.processing.rawValue
                        $0.claimedAt = #bind(now as Date?)
                        $0.attemptCount += 1
                        $0.lastError = nil as String?
                    }
                    .execute(db)

                var claimed = row
                claimed.status = IngestionJob.Status.processing.rawValue
                claimed.claimedAt = now
                claimed.attemptCount += 1
                claimed.lastError = nil
                return ingestionJob(from: claimed)
            }
        }
    }

    static func _completeIngestionJob(
        database: any DatabaseWriter
    ) -> @Sendable (UUID, Date) async throws -> Void {
        { id, now in
            try await database.write { db in
                try IngestionJobLocalTable
                    .find(id)
                    .update {
                        $0.status = IngestionJob.Status.completed.rawValue
                        $0.claimedAt = nil as Date?
                        $0.processedAt = #bind(now as Date?)
                        $0.lastError = nil as String?
                    }
                    .execute(db)
            }
        }
    }

    static func _failIngestionJob(
        database: any DatabaseWriter
    ) -> @Sendable (UUID, String, Date) async throws -> Void {
        { id, message, _ in
            try await database.write { db in
                guard let row = try IngestionJobLocalTable.find(id).fetchOne(db) else { return }
                try IngestionJobLocalTable
                    .find(id)
                    .update {
                        $0.status = row.attemptCount >= 3
                            ? IngestionJob.Status.failed.rawValue
                            : IngestionJob.Status.queued.rawValue
                        $0.claimedAt = nil as Date?
                        $0.lastError = #bind(message as String?)
                    }
                    .execute(db)
            }
        }
    }

    static func _fetchFailedIngestionJobs(
        database: any DatabaseWriter
    ) -> @Sendable () async throws -> [IngestionJob] {
        {
            try await database.read { db in
                try IngestionJobLocalTable
                    .where { $0.status.eq(IngestionJob.Status.failed.rawValue) }
                    .order { $0.createdAt }
                    .fetchAll(db)
                    .compactMap(ingestionJob(from:))
            }
        }
    }

    static func _retryFailedIngestionJobs(
        database: any DatabaseWriter
    ) -> @Sendable () async throws -> Void {
        {
            try await database.write { db in
                try IngestionJobLocalTable
                    .where { $0.status.eq(IngestionJob.Status.failed.rawValue) }
                    .update {
                        $0.status = IngestionJob.Status.queued.rawValue
                        $0.claimedAt = nil as Date?
                        $0.attemptCount = 0
                        $0.lastError = nil as String?
                    }
                    .execute(db)
            }
        }
    }

    static func _dismissFailedIngestionJobs(
        database: any DatabaseWriter
    ) -> @Sendable (Date) async throws -> Void {
        { now in
            try await database.write { db in
                try IngestionJobLocalTable
                    .where { $0.status.eq(IngestionJob.Status.failed.rawValue) }
                    .update {
                        $0.status = IngestionJob.Status.dismissed.rawValue
                        $0.processedAt = #bind(now as Date?)
                    }
                    .execute(db)
            }
        }
    }

    private static func ingestionJob(from row: IngestionJobLocalTable) -> IngestionJob? {
        guard
            let kind = IngestionJob.Kind(rawValue: row.kind),
            let status = IngestionJob.Status(rawValue: row.status)
        else { return nil }
        return IngestionJob(
            kind: kind,
            payload: row.payload,
            id: row.id,
            createdAt: row.createdAt,
            status: status,
            claimedAt: row.claimedAt,
            attemptCount: row.attemptCount,
            lastError: row.lastError
        )
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
            @Dependency(\.date.now)
            var now
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

    /// Backfills `SavedTextContentSyncTable` from local content for text items
    /// that are missing a sync row. Runs on every launch so that:
    ///   • Items created before the sync table existed get a row.
    ///   • Items whose sync row was lost (e.g. by a DROP TABLE migration) are
    ///     repopulated from the still-intact local content table.
    /// Only writes for text items (sourceURL is nil, renderFormat is not pdf).
    static func _backfillTextSyncTable(database: any DatabaseWriter) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            @Dependency(\.date.now)
            var now
            return try await database.write { db -> Int in
                // Find text items that have local content but no sync row.
                let locals = try SavedItemContentLocalTable
                    .where { $0.localStatus.eq("available") }
                    .fetchAll(db)
                var backfilled = 0
                for local in locals {
                    // Only text items — skip URL-sourced and PDF items.
                    guard let sync = try SavedItemSyncTable.find(local.itemID).fetchOne(db) else {
                        continue
                    }
                    guard sync.sourceURL == nil || sync.sourceURL?.isEmpty == true else {
                        continue
                    }
                    let format = RenderFormat(rawValue: local.renderFormat) ?? .structuredV1
                    guard format != .pdf else { continue }

                    // Skip if a sync row already exists with content.
                    if let existing = try SavedTextContentSyncTable.find(local.itemID).fetchOne(db),
                       !existing.rawSourceText.isEmpty {
                        continue
                    }

                    // Build the compressed raw source text for the sync row.
                    let rawText: String
                    if !local.rawSourceText.isEmpty {
                        rawText = local.rawSourceText
                    } else if !local.documentJSON.isEmpty,
                              let data = local.documentJSON.data(using: .utf8),
                              let document = try? JSONDecoder().decode(ReaderDocument.self, from: data),
                              !document.blocks.isEmpty {
                        rawText = ReaderDocumentMarkdownWriter.markdown(from: document)
                    } else {
                        rawText = local.plainText
                    }
                    guard !rawText.isEmpty else { continue }

                    let compressed = TextSyncCompression.compress(rawText)
                    let truncatedPlain = String(local.plainText.prefix(1000))

                    try SavedTextContentSyncTable
                        .upsert {
                            SavedTextContentSyncTable.Draft(
                                id: local.itemID,
                                plainText: truncatedPlain,
                                rawSourceText: compressed,
                                rawSourceMode: local.rawSourceMode,
                                renderFormat: local.renderFormat,
                                createdAt: now,
                                updatedAt: now
                            )
                        }
                        .execute(db)
                    backfilled += 1
                }
                return backfilled
            }
        }
    }

    /// Hydrates text/markdown items that arrived via CloudKit sync by enqueuing
    /// ingestion jobs. Unlike PDFs (which sync their full documentJSON), text
    /// items only sync `rawSourceText` to stay under CloudKit's 1 MB limit.
    /// The receiving device re-parses the raw source through the text ingestion
    /// client to rebuild the document blocks.
    static func _hydrateTextItemsFromSyncedContent(database: any DatabaseWriter) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            @Dependency(\.date.now)
            var now
            @Dependency(\.uuid)
            var uuid
            return try await database.write { db -> Int in
                let textRows: [SavedTextContentSyncTable] = try SavedTextContentSyncTable.fetchAll(db)
                var enqueued = 0
                for textRow in textRows {
                    // Skip if we already have rendered content locally.
                    let existing: SavedItemContentLocalTable? = try SavedItemContentLocalTable
                        .find(textRow.id)
                        .fetchOne(db)
                    if let existing, !existing.documentJSON.isEmpty {
                        continue
                    }

                    // Need the sync row to get the item title.
                    guard let sync = try SavedItemSyncTable.find(textRow.id).fetchOne(db) else {
                        continue
                    }

                    // Decompress the raw source text (stored compressed in the
                    // sync table to stay under CloudKit's 1 MB limit).
                    let rawSourceText = TextSyncCompression.decompress(textRow.rawSourceText)

                    // Create a placeholder local row so the library shows the
                    // item with its plainText excerpt while ingestion runs.
                    if existing == nil {
                        try SavedItemContentLocalTable
                            .insert {
                                SavedItemContentLocalTable.Draft(
                                    itemID: textRow.id,
                                    renderFormat: textRow.renderFormat,
                                    documentVersion: 1,
                                    plainText: textRow.plainText,
                                    documentJSON: "",
                                    sourceHTMLHash: "",
                                    sourceHTML: "",
                                    rawSourceText: rawSourceText,
                                    rawSourceMode: textRow.rawSourceMode,
                                    localStatus: "downloading",
                                    localError: nil,
                                    createdAt: now,
                                    updatedAt: now
                                )
                            }
                            .execute(db)
                    } else {
                        try SavedItemContentLocalTable
                            .find(textRow.id)
                            .update {
                                $0.localStatus = "downloading"
                                $0.updatedAt = now
                            }
                            .execute(db)
                    }

                    // Enqueue a hydrateText job so the text ingestion client
                    // can parse the raw source into document blocks.
                    let payload = TextHydrationPayload(
                        itemID: textRow.id,
                        rawSourceText: rawSourceText,
                        rawSourceMode: textRow.rawSourceMode,
                        title: sync.title
                    )
                    let payloadJSON = try String(
                        bytes: JSONEncoder().encode(payload),
                        encoding: .utf8
                    ) ?? ""
                    let existingJob = try IngestionJobLocalTable
                        .where { $0.kind.eq(IngestionJob.Kind.hydrateText.rawValue) }
                        .where { $0.payload.eq(payloadJSON) }
                        .where { $0.processedAt.is(nil) }
                        .fetchCount(db)
                    guard existingJob == 0 else { continue }
                    try IngestionJobLocalTable
                        .insert {
                            IngestionJobLocalTable.Draft(
                                id: uuid(),
                                kind: IngestionJob.Kind.hydrateText.rawValue,
                                payload: payloadJSON,
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

    static func _enqueueHydrationJobsForMissingContent(database: any DatabaseWriter) -> @Sendable () async throws -> Int {
        { () async throws -> Int in
            @Dependency(\.date.now)
            var now
            @Dependency(\.uuid)
            var uuid
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
                                id: uuid(),
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

private extension IngestionJob.Kind {
    var isHydrationJob: Bool {
        switch self {
        case .hydrate, .hydrateText, .hydrateWebsite:
            true
        case .url, .pdf, .website, .text, .markdown:
            false
        }
    }
}
