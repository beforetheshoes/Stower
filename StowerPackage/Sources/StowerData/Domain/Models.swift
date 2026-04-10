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
    /// Block index of the last-read position for scroll restoration. Nil means unread or at the top.
    public var lastReadBlockIndex: Int?
    public var isRead: Bool
    public var isStarred: Bool
    /// When set, this item is in the Recently Deleted bucket and will be
    /// permanently purged after the retention window expires.
    public var deletedAt: Date?
    /// IDs of tags assigned to this item. Populated by repository reads via a
    /// batched junction-table query (never N+1).
    public var tagIDs: [UUID]

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
        updatedAt: Date = .now,
        lastReadBlockIndex: Int? = nil,
        isRead: Bool = false,
        isStarred: Bool = false,
        deletedAt: Date? = nil,
        tagIDs: [UUID] = []
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
        self.lastReadBlockIndex = lastReadBlockIndex
        self.isRead = isRead
        self.isStarred = isStarred
        self.deletedAt = deletedAt
        self.tagIDs = tagIDs
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

public enum ReaderFontStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case newYork
    case timesNewRoman
    case helveticaNeue
    case avenirNext
    case menlo

    public var displayName: String {
        switch self {
        case .newYork:
            return "New York"
        case .timesNewRoman:
            return "Times"
        case .helveticaNeue:
            return "Helvetica"
        case .avenirNext:
            return "Avenir"
        case .menlo:
            return "Menlo"
        }
    }
}

public enum ReaderJustification: String, Codable, CaseIterable, Equatable, Sendable {
    case leading
    case justified
}

public enum ReaderTheme: String, Codable, CaseIterable, Equatable, Sendable {
    case white
    case sepia
    case dark
}

public struct ReaderAppearanceSettings: Equatable, Sendable {
    public static let fontSizeRange = 14.0 ... 30.0
    public static let lineSpacingRange = 2.0 ... 16.0
    public static let lineWidthRange = 260.0 ... 980.0

    public var fontSize: Double
    public var fontStyle: ReaderFontStyle
    public var lineSpacing: Double
    public var justification: ReaderJustification
    public var theme: ReaderTheme
    public var lineWidth: Double

    public init(
        fontSize: Double = 19,
        fontStyle: ReaderFontStyle = .newYork,
        lineSpacing: Double = 8,
        justification: ReaderJustification = .leading,
        theme: ReaderTheme = .white,
        lineWidth: Double = 820
    ) {
        self.fontSize = fontSize
        self.fontStyle = fontStyle
        self.lineSpacing = lineSpacing
        self.justification = justification
        self.theme = theme
        self.lineWidth = lineWidth
        self.clamp()
    }

    public mutating func clamp() {
        self.fontSize = min(max(self.fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.lineSpacing = min(max(self.lineSpacing, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
        self.lineWidth = min(max(self.lineWidth, Self.lineWidthRange.lowerBound), Self.lineWidthRange.upperBound)
    }

    public func clamped() -> Self {
        var copy = self
        copy.clamp()
        return copy
    }
}

public struct IngestionJob: Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case url
        case text
        case hydrate
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

public struct HydrationPayload: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var url: String

    public init(itemID: UUID, url: String) {
        self.itemID = itemID
        self.url = url
    }
}
