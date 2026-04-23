import CryptoKit
import Foundation
import SQLiteData

// MARK: - Domain Mapping

extension StowerRepository {
    static func progressUnitCount(from local: SavedItemContentLocalTable?) -> Int? {
        guard let local,
              !local.documentJSON.isEmpty,
              let data = local.documentJSON.data(using: .utf8),
              let document = try? JSONDecoder().decode(ReaderDocument.self, from: data),
              !document.blocks.isEmpty
        else {
            return nil
        }
        return document.blocks.count
    }

    static func toDomain(
        sync: SavedItemSyncTable,
        local: SavedItemContentLocalTable?,
        tagIDs: [UUID] = []
    ) -> SavedItem {
        SavedItem(
            title: sync.title,
            content: local?.plainText ?? "",
            id: sync.id,
            sourceURL: sync.sourceURL,
            canonicalURL: sync.canonicalURL,
            renderFormat: RenderFormat(rawValue: local?.renderFormat ?? "structuredV1") ?? .structuredV1,
            documentVersion: local?.documentVersion ?? 1,
            excerpt: sync.excerpt,
            heroImageURL: sync.heroImageURL,
            author: sync.author,
            publishedAt: sync.publishedAt,
            siteName: sync.siteName,
            readingTimeMinutes: sync.readingTimeMinutes,
            hasRichMedia: sync.hasRichMedia,
            processingState: processingState(from: local),
            processingError: local?.localError,
            createdAt: sync.createdAt,
            updatedAt: sync.updatedAt,
            lastReadBlockIndex: sync.lastReadBlockIndex,
            progressUnitCount: progressUnitCount(from: local),
            isRead: sync.isRead,
            isStarred: sync.isStarred,
            deletedAt: sync.deletedAt,
            tagIDs: tagIDs
        )
    }

    static func toDomain(from draft: SavedItemSyncTable.Draft, local: SavedItemContentLocalTable?, inferredContent: String) -> SavedItem {
        SavedItem(
            title: draft.title,
            content: local?.plainText ?? inferredContent,
            id: draft.id ?? UUID(),
            sourceURL: draft.sourceURL,
            canonicalURL: draft.canonicalURL,
            renderFormat: RenderFormat(rawValue: local?.renderFormat ?? "structuredV1") ?? .structuredV1,
            documentVersion: local?.documentVersion ?? 1,
            excerpt: draft.excerpt,
            heroImageURL: draft.heroImageURL,
            author: draft.author,
            publishedAt: draft.publishedAt,
            siteName: draft.siteName,
            readingTimeMinutes: draft.readingTimeMinutes,
            hasRichMedia: draft.hasRichMedia,
            processingState: processingState(from: local),
            processingError: local?.localError,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
            lastReadBlockIndex: draft.lastReadBlockIndex,
            progressUnitCount: progressUnitCount(from: local),
            isRead: draft.isRead,
            isStarred: draft.isStarred,
            deletedAt: draft.deletedAt
        )
    }

    static func toDomain(tag: TagSyncTable) -> Tag {
        Tag(
            name: tag.name,
            id: tag.id,
            colorHex: tag.colorHex,
            createdAt: tag.createdAt,
            updatedAt: tag.updatedAt
        )
    }

    static func processingState(from local: SavedItemContentLocalTable?) -> ProcessingState {
        switch local?.localStatus {
        case "available":
            return .ready
        case "downloading":
            return .extracting
        case "failed":
            return .failed
        default:
            return .queued
        }
    }

    static func makeSyncDraft(id: UUID, result: IngestionResult, now: Date) -> SavedItemSyncTable.Draft {
        // Defensively truncate all string fields to stay well under
        // CloudKit's 1 MB per-record limit.
        SavedItemSyncTable.Draft(
            id: id,
            title: String(result.title.prefix(500)),
            sourceURL: result.sourceURL,
            canonicalURL: result.canonicalURL,
            excerpt: result.excerpt.map { String($0.prefix(500)) },
            heroImageURL: result.heroImageURL,
            author: result.author.map { String($0.prefix(200)) },
            publishedAt: result.publishedAt,
            siteName: result.siteName.map { String($0.prefix(200)) },
            readingTimeMinutes: result.readingTimeMinutes,
            hasRichMedia: result.hasRichMedia,
            createdAt: now,
            updatedAt: now,
            isArchived: false
        )
    }

    static func persistLocalContentAndCaches(
        db: Database,
        itemID: UUID,
        result: IngestionResult,
        now: Date,
        updateLocalStatus: String
    ) throws {
        let documentJSON = try String(bytes: JSONEncoder().encode(result.document), encoding: .utf8) ?? ""
        let hash = sha256Hex(result.plainText)

        if try SavedItemContentLocalTable.find(itemID).fetchOne(db) != nil {
            try SavedItemContentLocalTable
                .find(itemID)
                .update {
                    $0.renderFormat = result.renderFormat.rawValue
                    $0.documentVersion = result.document.version
                    $0.plainText = result.plainText
                    $0.documentJSON = documentJSON
                    $0.sourceHTMLHash = hash
                    $0.sourceHTML = result.sourceHTML
                    $0.rawSourceText = result.rawSourceText ?? ""
                    $0.rawSourceMode = #bind(result.rawSourceMode?.rawValue)
                    $0.localStatus = updateLocalStatus
                    $0.localError = #bind(result.processingError)
                    $0.updatedAt = now
                    if let pdfHash = result.pdfSHA256 {
                        $0.pdfSHA256 = #bind(pdfHash)
                    }
                }
                .execute(db)
        } else {
            try SavedItemContentLocalTable
                .insert {
                    SavedItemContentLocalTable.Draft(
                        itemID: itemID,
                        renderFormat: result.renderFormat.rawValue,
                        documentVersion: result.document.version,
                        plainText: result.plainText,
                        documentJSON: documentJSON,
                        sourceHTMLHash: hash,
                        sourceHTML: result.sourceHTML,
                        rawSourceText: result.rawSourceText ?? "",
                        rawSourceMode: result.rawSourceMode?.rawValue,
                        localStatus: updateLocalStatus,
                        localError: result.processingError,
                        createdAt: now,
                        updatedAt: now,
                        pdfSHA256: result.pdfSHA256
                    )
                }
                .execute(db)
        }

        // For PDF items, also mirror the extracted document into the
        // CloudKit-synced table so the second device can render the structured
        // text view without having the PDF bytes (which never sync).
        if result.renderFormat == .pdf {
            try SavedPDFContentSyncTable
                .upsert {
                    SavedPDFContentSyncTable.Draft(
                        id: itemID,
                        documentJSON: documentJSON,
                        plainText: result.plainText,
                        createdAt: now,
                        updatedAt: now
                    )
                }
                .execute(db)
        }

        // For text/markdown items (no sourceURL), mirror the raw source into
        // the CloudKit-synced table so other devices can re-ingest it locally.
        // The raw text is zlib-compressed + base64-encoded to stay under
        // CloudKit's 1 MB per-record limit. plainText is truncated to 1000
        // chars (enough for excerpt display while the full content syncs).
        //
        // Scoped to text-oriented render formats only. Other formats that
        // happen to have a nil sourceURL (e.g. `.webView` from a user-
        // imported `.zip`) have their own sync tables — mirroring them here
        // would write empty rows every time the item updates, and the
        // resulting CloudKit echo floods the sync engine.
        let isTextAuthoredItem = result.sourceURL == nil
            && (
                result.renderFormat == .plainText
                || result.renderFormat == .structuredV1
                || result.renderFormat == .htmlFallback
            )
        if isTextAuthoredItem {
            let rawText = result.rawSourceText ?? ""
            let compressed = TextSyncCompression.compress(rawText)
            let truncatedPlain = String(result.plainText.prefix(1000))
            try SavedTextContentSyncTable
                .upsert {
                    SavedTextContentSyncTable.Draft(
                        id: itemID,
                        plainText: truncatedPlain,
                        rawSourceText: compressed,
                        rawSourceMode: result.rawSourceMode?.rawValue,
                        renderFormat: result.renderFormat.rawValue,
                        createdAt: now,
                        updatedAt: now
                    )
                }
                .execute(db)
        }

        // Media and embed rows have a UNIQUE constraint on (itemID, sourceURL)
        // / (itemID, embedURL). Clear any prior rows before re-inserting so
        // this helper is idempotent — callers hit it on create, update,
        // hydrate, and re-add after soft delete, and all of them would
        // otherwise need their own cleanup step.
        try SavedMediaLocalTable.where { $0.itemID.eq(itemID) }.delete().execute(db)
        try SavedEmbedLocalTable.where { $0.itemID.eq(itemID) }.delete().execute(db)

        for descriptor in result.media {
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

        for embed in result.embeds {
            try SavedEmbedLocalTable
                .insert {
                    SavedEmbedLocalTable.Draft(
                        id: UUID(),
                        itemID: itemID,
                        provider: embed.provider,
                        embedURL: embed.embedURL,
                        htmlSnippet: embed.htmlSnippet,
                        status: "ready",
                        createdAt: now,
                        updatedAt: now
                    )
                }
                .execute(db)
        }
    }
}

// MARK: - URL & Hash Utilities

extension StowerRepository {
    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Derives the deterministic UUID Stower uses as the primary key for a
    /// saved item, given its canonical URL. Public so that ingestion
    /// clients can pre-compute the item ID before `createItemFromIngestion`
    /// runs — e.g. PDF ingestion needs to know where on disk to write
    /// rasterized page images, and that path is rooted at the item ID.
    public static func stableItemID(from urlString: String?) -> UUID {
        guard let key = normalizedURLKey(urlString) else { return UUID() }
        let digest = SHA256.hash(data: Data(key.utf8))
        let bytes = Array(digest)
        var b = Array(bytes[0..<16])
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        var uuidBytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuidBytes) { $0.copyBytes(from: b) }
        return UUID(uuid: uuidBytes)
    }

    static func normalizedURLKey(_ urlString: String?) -> String? {
        guard let urlString, var components = URLComponents(string: urlString) else { return nil }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased() ?? "https"
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        let normalized = components.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}
