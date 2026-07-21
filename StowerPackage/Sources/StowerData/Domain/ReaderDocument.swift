import Foundation

public enum RenderFormat: String, Codable, Equatable, Sendable {
    case structuredV1 = "structuredV1"
    case htmlFallback = "htmlFallback"
    case plainText = "plainText"
    case webView = "webView"
    case pdf = "pdf"
}

public enum ProcessingState: String, Codable, Equatable, Sendable {
    case queued = "queued"
    case extracting = "extracting"
    case ready = "ready"
    case failed = "failed"
    case partial = "partial"
}

public struct ReaderDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var sourceURL: String?
    public var canonicalURL: String?
    public var title: String
    public var blocks: [ReaderBlock]

    public init(
        title: String,
        blocks: [ReaderBlock],
        version: Int = 1,
        sourceURL: String? = nil,
        canonicalURL: String? = nil
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
    case lineBreak
    case link(label: String, url: String)
    case emphasis(String)
    case strong(String)
    case code(String)
    case strikethrough(String)
}

public struct MediaDescriptor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case image = "image"
        case video = "video"
        case audio = "audio"
        case embed = "embed"
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
    /// Name of the platform providing the media (e.g. "YouTube"). Used by the
    /// reader renderer to branch into platform-specific embed layouts.
    public var providerName: String?
    /// Canonical video identifier within the provider (e.g. the 11-char YouTube ID).
    public var providerVideoID: String?
    /// On-disk path to a cached poster/thumbnail image for this media. When set and
    /// the file exists, the reader prefers this over the remote `posterURL` so the
    /// thumbnail is visible offline.
    public var posterLocalURL: String?
    /// Author/channel display name for provider-sourced media.
    public var authorName: String?

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
        altText: String? = nil,
        providerName: String? = nil,
        providerVideoID: String? = nil,
        posterLocalURL: String? = nil,
        authorName: String? = nil
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
        self.providerName = providerName
        self.providerVideoID = providerVideoID
        self.posterLocalURL = posterLocalURL
        self.authorName = authorName
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
    public var rawSourceText: String?
    public var rawSourceMode: TextImportMode?
    /// The raw HTML of the article section (or full page for webView render format).
    public var sourceHTML: String
    /// SHA-256 hex digest of the original PDF bytes. Only populated for
    /// `renderFormat == .pdf`. Used by the ingestion pipeline to find the
    /// staged PDF file in temp so it can be moved into the archive directory
    /// after the item ID is assigned.
    public var pdfSHA256: String?
    /// Staged exact web capture. Persistence installs this package atomically
    /// after the database item has its stable ID.
    public var webCapture: WebCaptureArtifact?

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
        rawSourceText: String? = nil,
        rawSourceMode: TextImportMode? = nil,
        sourceHTML: String = "",
        pdfSHA256: String? = nil,
        webCapture: WebCaptureArtifact? = nil
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
        self.rawSourceText = rawSourceText
        self.rawSourceMode = rawSourceMode
        self.sourceHTML = sourceHTML
        self.pdfSHA256 = pdfSHA256
        self.webCapture = webCapture
    }

    public static func sharedText(
        _ text: String,
        explicitTitle: String? = nil,
        titleHint: String? = nil,
        rawSourceText: String? = nil,
        rawSourceMode: TextImportMode? = nil
    ) -> IngestionResult {
        let normalized = normalizeTextForStorage(text)
        let resolvedTitle = resolvedTextImportTitle(
            explicitTitle: explicitTitle,
            documentTitle: nil,
            titleHint: titleHint
        )
        let document = ReaderDocument(
            title: resolvedTitle,
            blocks: plainTextBlocks(from: normalized)
        )
        return IngestionResult(
            title: resolvedTitle,
            sourceURL: nil,
            canonicalURL: nil,
            excerpt: String(normalized.prefix(180)),
            author: nil,
            publishedAt: nil,
            siteName: nil,
            heroImageURL: nil,
            readingTimeMinutes: max(1, normalized.split(separator: " ").count / 225),
            hasRichMedia: false,
            renderFormat: .plainText,
            processingState: .ready,
            processingError: nil,
            document: document,
            plainText: normalized,
            media: [],
            embeds: [],
            rawSourceText: rawSourceText,
            rawSourceMode: rawSourceMode
        )
    }

    /// Builds an `IngestionResult` for a user-imported interactive website
    /// archive. Produces a minimal `.webView` item — the reader renders from
    /// the unpacked files on disk, not from `document`/`plainText`, so those
    /// stay empty. `excerpt` carries the original filename so the library
    /// card has something readable before the `<title>` tag is parsed.
    public static func importedWebsite(
        title: String,
        filename: String,
        heroImageURL: String? = nil
    ) -> IngestionResult {
        IngestionResult(
            title: title,
            sourceURL: nil,
            canonicalURL: nil,
            excerpt: filename.isEmpty ? nil : filename,
            author: nil,
            publishedAt: nil,
            siteName: nil,
            heroImageURL: heroImageURL,
            readingTimeMinutes: nil,
            hasRichMedia: true,
            renderFormat: .webView,
            processingState: .ready,
            processingError: nil,
            document: ReaderDocument(title: title, blocks: []),
            plainText: "",
            media: [],
            embeds: [],
            sourceHTML: ""
        )
    }

    public static func structuredText(
        title: String,
        blocks: [ReaderBlock],
        plainText: String,
        rawSourceText: String? = nil,
        rawSourceMode: TextImportMode? = nil,
        sourceURL: String? = nil,
        canonicalURL: String? = nil
    ) -> IngestionResult {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = ReaderDocument(
            title: title,
            blocks: blocks
        )
        return IngestionResult(
            title: title,
            sourceURL: sourceURL,
            canonicalURL: canonicalURL,
            excerpt: String(trimmed.prefix(180)),
            author: nil,
            publishedAt: nil,
            siteName: nil,
            heroImageURL: nil,
            readingTimeMinutes: max(1, trimmed.split(separator: " ").count / 225),
            hasRichMedia: false,
            renderFormat: .structuredV1,
            processingState: .ready,
            processingError: nil,
            document: document,
            plainText: trimmed,
            media: [],
            embeds: [],
            rawSourceText: rawSourceText,
            rawSourceMode: rawSourceMode
        )
    }
}

public struct WebCaptureArtifact: Equatable, Sendable {
    public let captureID: UUID
    public let version: Int
    public let stagedPackageURL: URL
    public let sha256: String
    public let byteCount: Int
    public let completeness: WebCaptureCompleteness
    public let warnings: [String]

    public init(
        captureID: UUID,
        version: Int = 1,
        stagedPackageURL: URL,
        sha256: String,
        byteCount: Int,
        completeness: WebCaptureCompleteness,
        warnings: [String] = []
    ) {
        self.captureID = captureID
        self.version = version
        self.stagedPackageURL = stagedPackageURL
        self.sha256 = sha256
        self.byteCount = byteCount
        self.completeness = completeness
        self.warnings = warnings
    }
}

private func normalizeTextForStorage(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func plainTextBlocks(from text: String) -> [ReaderBlock] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var paragraphs = [[String]]()
    var current = [String]()

    for line in lines {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if !current.isEmpty {
                paragraphs.append(current)
                current = []
            }
            continue
        }
        current.append(line)
    }

    if !current.isEmpty {
        paragraphs.append(current)
    }

    guard !paragraphs.isEmpty else {
        return [.paragraph([])]
    }

    return paragraphs.map { lines in
        var inlines = [ReaderInline]()
        for (index, line) in lines.enumerated() {
            inlines.append(.text(line))
            if index < lines.count - 1 {
                inlines.append(.lineBreak)
            }
        }
        return .paragraph(inlines)
    }
}

// MARK: - Markdown Reconstruction

/// Converts a `ReaderDocument`'s blocks back to markdown source text.
/// Used when `rawSourceText` is empty and the editor needs markdown to display.
public enum ReaderDocumentMarkdownWriter {
    public static func markdown(from document: ReaderDocument) -> String {
        document.blocks
            .map(blockToMarkdown)
            .joined(separator: "\n\n")
    }

    private static func blockToMarkdown(_ block: ReaderBlock) -> String {
        switch block {
        case .paragraph(let inlines):
            return inlinesToMarkdown(inlines)

        case let .heading(level, inlines):
            let hashes = String(repeating: "#", count: min(max(level, 1), 6))
            return "\(hashes) \(inlinesToMarkdown(inlines))"

        case let .list(ordered, items):
            return items.enumerated()
                .map { index, inlines in
                    let marker = ordered ? "\(index + 1)." : "-"
                    return "\(marker) \(inlinesToMarkdown(inlines))"
                }
                .joined(separator: "\n")

        case .blockquote(let inlines):
            let text = inlinesToMarkdown(inlines)
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")

        case let .code(language, code):
            let fence = "```"
            let lang = language ?? ""
            return "\(fence)\(lang)\n\(code)\n\(fence)"

        case .table(let markdown):
            return markdown

        case .horizontalRule:
            return "---"

        case let .callout(title, inlines):
            let body = inlinesToMarkdown(inlines)
            if let title, !title.isEmpty {
                return "> **\(title)**\n> \(body)"
            }
            return "> \(body)"

        case .figure(let media):
            let alt = media.altText ?? media.caption ?? ""
            if media.sourceURL.hasPrefix("stower://") {
                return alt.isEmpty ? "" : alt
            }
            return "![\(alt)](\(media.sourceURL))"

        case .video(let media):
            let label = media.caption ?? media.sourceURL
            return "[\(label)](\(media.sourceURL))"

        case .embed(let embed):
            return "[\(embed.provider)](\(embed.embedURL))"
        }
    }

    static func inlinesToMarkdown(_ inlines: [ReaderInline]) -> String {
        inlines.map(inlineToMarkdown).joined()
    }

    private static func inlineToMarkdown(_ inline: ReaderInline) -> String {
        switch inline {
        case .text(let value):
            return value
        case .lineBreak:
            return "  \n"
        case let .link(label, url):
            return "[\(label)](\(url))"
        case .emphasis(let value):
            return "*\(value)*"
        case .strong(let value):
            return "**\(value)**"
        case .code(let value):
            return "`\(value)`"
        case .strikethrough(let value):
            return "~~\(value)~~"
        }
    }
}
