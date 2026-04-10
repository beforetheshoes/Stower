import Foundation

public enum RenderFormat: String, Codable, Equatable, Sendable {
    case structuredV1
    case htmlFallback
    case plainText
    case webView
}

public enum ProcessingState: String, Codable, Equatable, Sendable {
    case queued
    case extracting
    case ready
    case failed
    case partial
}

public struct ReaderDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var sourceURL: String?
    public var canonicalURL: String?
    public var title: String
    public var blocks: [ReaderBlock]

    public init(
        version: Int = 1,
        sourceURL: String? = nil,
        canonicalURL: String? = nil,
        title: String,
        blocks: [ReaderBlock]
    ) {
        self.version = version
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.title = title
        self.blocks = blocks
    }
}

public enum ReaderBlock: Codable, Equatable, Sendable {
    case paragraph([ReaderInline])
    case heading(level: Int, inlines: [ReaderInline])
    case list(ordered: Bool, items: [[ReaderInline]])
    case blockquote([ReaderInline])
    case code(language: String?, code: String)
    case figure(media: MediaDescriptor)
    case video(media: MediaDescriptor)
    case embed(EmbedDescriptor)
    case table(markdown: String)
    case horizontalRule
    case callout(title: String?, inlines: [ReaderInline])
}

public enum ReaderInline: Codable, Equatable, Sendable {
    case text(String)
    case link(label: String, url: String)
    case emphasis(String)
    case strong(String)
    case code(String)
    case strikethrough(String)
}

public struct MediaDescriptor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case image
        case video
        case audio
        case embed
    }

    public var kind: Kind
    public var sourceURL: String
    public var localURL: String?
    public var mimeType: String?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var posterURL: String?
    public var caption: String?
    public var altText: String?

    public init(
        kind: Kind,
        sourceURL: String,
        localURL: String? = nil,
        mimeType: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        posterURL: String? = nil,
        caption: String? = nil,
        altText: String? = nil
    ) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.localURL = localURL
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.posterURL = posterURL
        self.caption = caption
        self.altText = altText
    }
}

public struct EmbedDescriptor: Codable, Equatable, Sendable {
    public var provider: String
    public var embedURL: String
    public var htmlSnippet: String?

    public init(provider: String, embedURL: String, htmlSnippet: String? = nil) {
        self.provider = provider
        self.embedURL = embedURL
        self.htmlSnippet = htmlSnippet
    }
}

public struct IngestionResult: Equatable, Sendable {
    public var title: String
    public var sourceURL: String?
    public var canonicalURL: String?
    public var excerpt: String?
    public var author: String?
    public var publishedAt: Date?
    public var siteName: String?
    public var heroImageURL: String?
    public var readingTimeMinutes: Int?
    public var hasRichMedia: Bool
    public var renderFormat: RenderFormat
    public var processingState: ProcessingState
    public var processingError: String?
    public var document: ReaderDocument
    public var plainText: String
    public var media: [MediaDescriptor]
    public var embeds: [EmbedDescriptor]
    /// The raw HTML of the article section (or full page for webView render format).
    public var sourceHTML: String

    public init(
        title: String,
        sourceURL: String?,
        canonicalURL: String?,
        excerpt: String?,
        author: String?,
        publishedAt: Date?,
        siteName: String?,
        heroImageURL: String?,
        readingTimeMinutes: Int?,
        hasRichMedia: Bool,
        renderFormat: RenderFormat,
        processingState: ProcessingState,
        processingError: String?,
        document: ReaderDocument,
        plainText: String,
        media: [MediaDescriptor],
        embeds: [EmbedDescriptor],
        sourceHTML: String = ""
    ) {
        self.title = title
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.excerpt = excerpt
        self.author = author
        self.publishedAt = publishedAt
        self.siteName = siteName
        self.heroImageURL = heroImageURL
        self.readingTimeMinutes = readingTimeMinutes
        self.hasRichMedia = hasRichMedia
        self.renderFormat = renderFormat
        self.processingState = processingState
        self.processingError = processingError
        self.document = document
        self.plainText = plainText
        self.media = media
        self.embeds = embeds
        self.sourceHTML = sourceHTML
    }

    public static func sharedText(_ text: String) -> IngestionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = ReaderDocument(
            title: "Shared Note",
            blocks: [.paragraph([.text(trimmed)])]
        )
        return IngestionResult(
            title: "Shared Note",
            sourceURL: nil,
            canonicalURL: nil,
            excerpt: String(trimmed.prefix(180)),
            author: nil,
            publishedAt: nil,
            siteName: nil,
            heroImageURL: nil,
            readingTimeMinutes: max(1, trimmed.split(separator: " ").count / 225),
            hasRichMedia: false,
            renderFormat: .plainText,
            processingState: .ready,
            processingError: nil,
            document: document,
            plainText: trimmed,
            media: [],
            embeds: []
        )
    }
}
