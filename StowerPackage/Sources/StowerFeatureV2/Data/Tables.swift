import Foundation
import SQLiteData

@Table
public nonisolated struct SavedItemTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String = ""
    public var sourceURL: String?
    public var canonicalURL: String?
    public var renderFormat: String = "structuredV1"
    public var documentVersion: Int = 1
    public var content: String = ""
    public var excerpt: String?
    public var heroImageURL: String?
    public var author: String?
    public var publishedAt: Date?
    public var siteName: String?
    public var readingTimeMinutes: Int?
    public var hasRichMedia: Bool = false
    public var processingState: String = "queued"
    public var processingError: String?
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
    public var isArchived: Bool = false
}

@Table
public nonisolated struct SavedDocumentTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var json: String = ""
    public var plainText: String = ""
    public var sourceHTMLHash: String = ""
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}

@Table
public nonisolated struct SavedMediaTable: Hashable, Identifiable, Sendable {
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
public nonisolated struct SavedEmbedTable: Hashable, Identifiable, Sendable {
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
public nonisolated struct SavedImageRefTable: Hashable, Identifiable, Sendable {
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
public nonisolated struct SavedImageAssetTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var imageData: Data = Data()
    public var width: Int = 0
    public var height: Int = 0
    public var format: String = "jpg"
    public var createdAt: Date = .now
}

@Table
public nonisolated struct ImageDownloadSettingsTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var globalAutoDownload: Bool = false
    public var askForNewSources: Bool = true
    public var updatedAt: Date = .now
}

@Table
public nonisolated struct IngestionJobTable: Hashable, Identifiable, Sendable {
    public let id: UUID
    public var kind: String = "url"
    public var payload: String = ""
    public var createdAt: Date = .now
    public var processedAt: Date?
}
