import Foundation

public struct SavedItem: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var sourceURL: String?
    public var canonicalURL: String?
    public var renderFormat: RenderFormat
    public var documentVersion: Int
    public var content: String
    public var excerpt: String?
    public var heroImageURL: String?
    public var author: String?
    public var publishedAt: Date?
    public var siteName: String?
    public var readingTimeMinutes: Int?
    public var hasRichMedia: Bool
    public var processingState: ProcessingState
    public var processingError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        sourceURL: String? = nil,
        canonicalURL: String? = nil,
        renderFormat: RenderFormat = .plainText,
        documentVersion: Int = 1,
        content: String,
        excerpt: String? = nil,
        heroImageURL: String? = nil,
        author: String? = nil,
        publishedAt: Date? = nil,
        siteName: String? = nil,
        readingTimeMinutes: Int? = nil,
        hasRichMedia: Bool = false,
        processingState: ProcessingState = .ready,
        processingError: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.renderFormat = renderFormat
        self.documentVersion = documentVersion
        self.content = content
        self.excerpt = excerpt
        self.heroImageURL = heroImageURL
        self.author = author
        self.publishedAt = publishedAt
        self.siteName = siteName
        self.readingTimeMinutes = readingTimeMinutes
        self.hasRichMedia = hasRichMedia
        self.processingState = processingState
        self.processingError = processingError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ImageDownloadSettings: Equatable, Sendable {
    public var globalAutoDownload: Bool
    public var askForNewSources: Bool

    public init(globalAutoDownload: Bool = false, askForNewSources: Bool = true) {
        self.globalAutoDownload = globalAutoDownload
        self.askForNewSources = askForNewSources
    }
}

public struct IngestionJob: Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case url
        case text
    }

    public let id: UUID
    public let kind: Kind
    public let payload: String
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, payload: String, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}
