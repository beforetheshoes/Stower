import Foundation
import SQLiteData

// MARK: - Synced (CloudKit) Tables

@Table
public nonisolated struct SavedItemSyncTable: Hashable, Identifiable, Sendable {
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
public nonisolated struct TagSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String = ""
    public var colorHex: String?
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

/// Junction row assigning a tag to a saved item. Its own `id` so CloudKit
/// records have a stable name; uniqueness is enforced by a composite index.
@Table
public nonisolated struct ItemTagSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var tagID: UUID
    public var createdAt: Date = .now
}

// MARK: - Local-Only Tables

@Table
public nonisolated struct SavedItemContentLocalTable: Hashable, Identifiable, Sendable {
    @Column(primaryKey: true)
    public let itemID: UUID

    public var renderFormat: String = "structuredV1"
    public var documentVersion: Int = 1
    public var plainText: String = ""
    public var documentJSON: String = ""
    public var sourceHTMLHash: String = ""
    public var sourceHTML: String = ""
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

/// CloudKit-synced extracted text for PDF items. Populated when a PDF is
/// ingested on any device; the second device reads this row to hydrate the
/// local content table without re-fetching the (unavailable) PDF bytes.
/// Never populated for URL/text items — those hydrate from the source URL.
@Table
public nonisolated struct SavedPDFContentSyncTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var documentJSON: String = ""
    public var plainText: String = ""
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

@Table
public nonisolated struct SavedMediaLocalTable: Hashable, Identifiable, Sendable {
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
public nonisolated struct SavedEmbedLocalTable: Hashable, Identifiable, Sendable {
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
public nonisolated struct SavedImageRefLocalTable: Hashable, Identifiable, Sendable {
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
public nonisolated struct SavedImageAssetLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var imageData: Data = Data()
    public var width: Int = 0
    public var height: Int = 0
    public var format: String = "jpg"
    public var createdAt: Date = .now
}

@Table
public nonisolated struct ImageDownloadSettingsLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var globalAutoDownload: Bool = false
    public var askForNewSources: Bool = true
    public var updatedAt: Date = .now
}

@Table
public nonisolated struct ReaderAppearanceSettingsLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var fontSize: Double = 19
    public var fontStyle: String = "newYork"
    public var lineSpacing: Double = 8
    public var justification: String = "leading"
    public var theme: String = "white"
    public var lineWidth: Double = 820
    public var updatedAt: Date = .now
}

@Table
public nonisolated struct IngestionJobLocalTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var kind: String = "url"
    public var payload: String = ""
    public var createdAt: Date = .now
    public var processedAt: Date?
}

