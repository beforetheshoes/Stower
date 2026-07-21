import Foundation
import SQLiteData

// MARK: - Synced (CloudKit) Tables

@Table
nonisolated public struct SavedItemSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String = ""
    public var sourceURL: String?
    public var canonicalURL: String?
    public var excerpt: String?
    public var heroImageURL: String?
    public var author: String?
    public var publishedAt: Date?
    public var siteName: String?
    public var readingTimeMinutes: Int?
    public var hasRichMedia: Bool = false
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
    public var isArchived: Bool = false
    /// Index of the top-most visible block the last time this article was read.
    /// Used to restore scroll position across sessions and devices.
    /// Nil means the user has never scrolled past the top (or hasn't read it yet).
    public var lastReadBlockIndex: Int?
    /// Whether the user has marked this item as read. Auto-flipped when the
    /// reader scrolls past the first block; also toggleable manually.
    public var isRead: Bool = false
    /// Whether the user has starred this item.
    public var isStarred: Bool = false
    /// Soft-delete timestamp. NULL means the item is live; non-NULL places it
    /// in the Recently Deleted list until the 30-day retention window expires.
    public var deletedAt: Date?
}

/// A user-created tag. CloudKit-synced; case-insensitively unique by name.
@Table
nonisolated public struct TagSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String = ""
    public var colorHex: String?
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

/// Junction row assigning a tag to a saved item. Its own `id` so CloudKit
/// records have a stable name; uniqueness is enforced by a composite index.
@Table
nonisolated public struct ItemTagSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var tagID: UUID
    public var createdAt: Date = .now
}

// MARK: - Local-Only Tables

@Table
nonisolated public struct SavedItemContentLocalTable: Hashable, Identifiable, Sendable {
    @Column(primaryKey: true)
    public let itemID: UUID

    public var renderFormat: String = "structuredV1"
    public var documentVersion: Int = 1
    public var plainText: String = ""
    public var documentJSON: String = ""
    public var sourceHTMLHash: String = ""
    public var sourceHTML: String = ""
    /// Nil/zero denotes an existing legacy item that still renders from
    /// `sourceHTML`. New captures install native Reader and Original archives.
    public var captureID: UUID?
    public var captureVersion: Int = 0
    public var rawSourceText: String = ""
    public var rawSourceMode: String?
    public var localStatus: String = "notDownloaded"  // notDownloaded, downloading, available, failed
    public var localError: String?
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
    /// On-device AI summary generated via Foundation Models.
    /// Nil until the user first requests a summary. Local-only (not synced
    /// via CloudKit) — summaries are regenerated per device on demand.
    public var summary: String?
    /// Timestamp of the most recent summary generation. Nil iff `summary` is nil.
    public var summaryGeneratedAt: Date?
    /// SHA-256 hex digest of the original PDF bytes for items with
    /// `renderFormat == "pdf"`. Nil for URL/text items. Used for dedup and
    /// to recognize a locally-stored PDF on subsequent shares.
    public var pdfSHA256: String?

    public var id: UUID { itemID }
}

/// Versioned, local-only AI output. Keeping summaries in their own table lets
/// the reader cache Quick and Enhanced results independently and invalidates a
/// cache entry whenever either the prompt or article text changes.
@Table
nonisolated public struct ArticleSummaryLocalTable: Hashable, Identifiable, Sendable {
    @Column(primaryKey: true)
    public let id: String

    public let itemID: UUID
    public let quality: String
    public let promptVersion: Int
    public let contentHash: String
    public let text: String
    public let generatedAt: Date
}

/// CloudKit-synced extracted text for PDF items. Populated when a PDF is
/// ingested on any device; the second device reads this row to hydrate the
/// local content table without re-fetching the (unavailable) PDF bytes.
/// Never populated for URL/text items — those hydrate from the source URL.
@Table
nonisolated public struct SavedPDFContentSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var documentJSON: String = ""
    public var plainText: String = ""
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

/// CloudKit-synced content for text/markdown items. Populated when a text
/// item is created or edited on any device; the second device reads this row
/// to hydrate the local content table without a source URL to re-fetch from.
/// Mirrors `SavedPDFContentSyncTable` but carries `rawSourceText` instead of
/// `documentJSON` — the receiving device re-parses the raw source to rebuild
/// the document blocks, keeping each CloudKit record well under the 1 MB limit.
@Table
nonisolated public struct SavedTextContentSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var plainText: String = ""
    public var rawSourceText: String = ""
    public var rawSourceMode: String?
    public var renderFormat: String = "plainText"
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

/// CloudKit-synced original zip bytes for user-imported interactive website
/// archives. The column `zipData` is a SQLite BLOB; SQLiteData's CloudKit
/// bridge promotes blob columns to `CKAsset` automatically, so sites up to a
/// few hundred MB sync within the user's iCloud quota. The second device runs
/// a `.hydrateWebsite` job that unpacks the bytes into the item's archive
/// directory on first open.
@Table
nonisolated public struct SavedWebsiteArchiveSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    // `@Table` macro requires an explicit type annotation so the
    // generated memberwise initializer and row bindings know this column
    // is a BLOB rather than having its type inferred at the call site.
    public var zipData: Data = .init()
    public var sha256: String = ""
    public var originalFilename: String = ""
    public var byteCount: Int = 0
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

/// Authoritative metadata for a captured web article package. Package bytes
/// live in chunk rows so a receiving device can reject stale or incomplete
/// captures before replacing its installed archive.
@Table
nonisolated public struct SavedArticleCaptureSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var captureID: UUID
    public var version: Int = 1
    public var sha256: String = ""
    public var byteCount: Int = 0
    public var chunkCount: Int = 0
    public var capturedAt: Date = .now
    public var updatedAt: Date = .now
}

/// One CloudKit-asset-sized slice of a versioned article capture. UUID primary
/// keys and the absence of uniqueness constraints keep this SyncEngine-safe.
@Table
nonisolated public struct SavedArticleCaptureChunkSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var captureID: UUID
    public var sequence: Int = 0
    public var data: Data = .init()
    public var byteCount: Int = 0
    public var sha256: String = ""
    public var createdAt: Date = .now
}

@Table
nonisolated public struct SavedMediaLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var kind: String = "image"
    public var sourceURL: String = ""
    public var localURL: String?
    public var mimeType: String?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var posterURL: String?
    public var caption: String?
    public var status: String = "ready"
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

@Table
nonisolated public struct SavedEmbedLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var provider: String = ""
    public var embedURL: String = ""
    public var htmlSnippet: String?
    public var status: String = "ready"
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

@Table
nonisolated public struct SavedImageRefLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var sourceURL: String?
    public var width: Int = 0
    public var height: Int = 0
    public var sha256: String = ""
    public var status: String = "pending"
    public var createdAt: Date = .now
}

@Table
nonisolated public struct SavedImageAssetLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var imageData: Data = .init()
    public var width: Int = 0
    public var height: Int = 0
    public var format: String = "jpg"
    public var createdAt: Date = .now
}

@Table
nonisolated public struct ImageDownloadSettingsLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var globalAutoDownload: Bool = false
    public var askForNewSources: Bool = true
    public var updatedAt: Date = .now
}

@Table
nonisolated public struct ReaderAppearanceSettingsLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var fontSize: Double = 19
    public var fontStyle: String = "newYork"
    public var lineSpacing: Double = 8
    public var justification: String = "leading"
    /// Stores the `ReaderBackground` raw value. Legacy rows may still contain
    /// `white|sepia|dark` — `ReaderBackground.fromStored(_:)` maps them.
    public var theme: String = "paper"
    public var primaryAccent: String = "blue"
    public var secondaryAccent: String = "purple"
    public var lineWidth: Double = 820
    public var updatedAt: Date = .now
}

@Table
nonisolated public struct IngestionJobLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var kind: String = "url"
    public var payload: String = ""
    public var createdAt: Date = .now
    public var processedAt: Date?
    public var status: String = "queued"
    public var claimedAt: Date?
    public var attemptCount: Int = 0
    public var lastError: String?
}
