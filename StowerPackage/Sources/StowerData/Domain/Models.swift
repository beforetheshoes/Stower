import Foundation

public struct SavedItem: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var sourceURL: String?
    public var canonicalURL: String?
    public var renderFormat: RenderFormat
    public var documentVersion: Int
    public var captureVersion: Int
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
    /// Total number of readable content units used to derive reading progress.
    /// For document-backed content this is typically `ReaderDocument.blocks.count`.
    public var progressUnitCount: Int?
    public var isRead: Bool
    public var isStarred: Bool
    /// When set, this item is in the Recently Deleted bucket and will be
    /// permanently purged after the retention window expires.
    public var deletedAt: Date?
    /// IDs of tags assigned to this item. Populated by repository reads via a
    /// batched junction-table query (never N+1).
    public var tagIDs = [UUID]()

    public init(
        title: String,
        content: String,
        id: UUID = UUID(),
        sourceURL: String? = nil,
        canonicalURL: String? = nil,
        renderFormat: RenderFormat = .plainText,
        documentVersion: Int = 1,
        captureVersion: Int = 0,
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
        progressUnitCount: Int? = nil,
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
        self.captureVersion = captureVersion
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
        self.progressUnitCount = progressUnitCount
        self.isRead = isRead
        self.isStarred = isStarred
        self.deletedAt = deletedAt
        self.tagIDs = tagIDs
    }
}

public enum WebCaptureCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case partial
}

/// Synced identity and integrity information for one immutable capture.
public struct WebCaptureManifest: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let captureID: UUID
    public let version: Int
    public let sha256: String
    public let byteCount: Int
    public let chunkCount: Int
    public let capturedAt: Date

    public init(
        itemID: UUID,
        captureID: UUID,
        version: Int = 1,
        sha256: String,
        byteCount: Int,
        chunkCount: Int,
        capturedAt: Date = .now
    ) {
        self.itemID = itemID
        self.captureID = captureID
        self.version = version
        self.sha256 = sha256
        self.byteCount = byteCount
        self.chunkCount = chunkCount
        self.capturedAt = capturedAt
    }
}

public struct WebCaptureChunk: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sequence: Int
    public let data: Data
    public let sha256: String

    public init(id: UUID = UUID(), sequence: Int, data: Data, sha256: String) {
        self.id = id
        self.sequence = sequence
        self.data = data
        self.sha256 = sha256
    }
}

public struct SyncedWebCapture: Equatable, Sendable {
    public let manifest: WebCaptureManifest
    public let chunks: [WebCaptureChunk]

    public init(manifest: WebCaptureManifest, chunks: [WebCaptureChunk]) {
        self.manifest = manifest
        self.chunks = chunks
    }
}

public struct ReadingProgressSnapshot: Equatable, Sendable {
    public let currentUnitIndex: Int
    public let totalUnitCount: Int

    public init?(currentUnitIndex: Int, totalUnitCount: Int) {
        guard totalUnitCount > 1 else { return nil }
        let clampedIndex = min(max(currentUnitIndex, 0), totalUnitCount - 1)
        guard clampedIndex < totalUnitCount - 1 else { return nil }
        self.currentUnitIndex = clampedIndex
        self.totalUnitCount = totalUnitCount
    }

    public var fractionComplete: Double {
        Double(currentUnitIndex) / Double(totalUnitCount)
    }

    public var percentComplete: Int {
        Int((fractionComplete * 100).rounded())
    }
}

extension SavedItem {
    public var libraryReadingProgress: ReadingProgressSnapshot? {
        guard renderFormat != .webView,
              isRead,
              let lastReadBlockIndex,
              let progressUnitCount
        else {
            return nil
        }
        return ReadingProgressSnapshot(
            currentUnitIndex: lastReadBlockIndex,
            totalUnitCount: progressUnitCount
        )
    }
}


/// A cached AI summary for an article. Persisted locally and never synced via
/// CloudKit. `quality` and `promptVersion` prevent a Quick result from being
/// served as an Enhanced result after the summarization prompts change.
public struct CachedSummary: Equatable, Sendable {
    public let text: String
    public let generatedAt: Date
    public let quality: String
    public let promptVersion: Int

    public init(
        text: String,
        generatedAt: Date,
        quality: String = "quick",
        promptVersion: Int = 1
    ) {
        self.text = text
        self.generatedAt = generatedAt
        self.quality = quality
        self.promptVersion = promptVersion
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
    case newYork = "newYork"
    case timesNewRoman = "timesNewRoman"
    case helveticaNeue = "helveticaNeue"
    case avenirNext = "avenirNext"
    case menlo = "menlo"

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
    case leading = "leading"
    case justified = "justified"
}

/// The background palette driving the whole app — not just the reader.
/// Picking `.black` switches the app into dark mode; the three light options
/// switch it into light mode. Sepia is a custom warm-cream palette tuned to
/// harmonise with Flexoki accent hues.
public enum ReaderBackground: String, Codable, CaseIterable, Equatable, Sendable {
    case paper = "paper"
    case white = "white"
    case sepia = "sepia"
    case black = "black"

    public var displayName: String {
        switch self {
        case .paper:
            return "Paper"
        case .white:
            return "White"
        case .sepia:
            return "Sepia"
        case .black:
            return "Black"
        }
    }

    /// Safe decode from legacy stored values. Pre-Flexoki databases persisted
    /// `white|sepia|dark`; the migration rewrites them at the SQL layer, but
    /// this fallback keeps us robust against any stragglers (e.g. rows
    /// inserted by older app versions mid-migration, sync replay, etc.).
    public static func fromStored(_ raw: String?) -> ReaderBackground {
        guard let raw else { return .paper }
        if let exact = ReaderBackground(rawValue: raw) {
            return exact
        }
        switch raw {
        case "dark":
            return .black
        case "white":
            return .white
        default:
            return .paper
        }
    }
}

/// The eight Flexoki accent hues the user can pick from. Each resolves to
/// different shades depending on whether the current background is light or
/// dark — see `FlexokiRaw.accent(_:isDark:)`.
public enum FlexokiHue: String, Codable, CaseIterable, Equatable, Sendable {
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case cyan = "cyan"
    case blue = "blue"
    case purple = "purple"
    case magenta = "magenta"

    public var displayName: String {
        switch self {
        case .red:
            return "Red"
        case .orange:
            return "Orange"
        case .yellow:
            return "Yellow"
        case .green:
            return "Green"
        case .cyan:
            return "Cyan"
        case .blue:
            return "Blue"
        case .purple:
            return "Purple"
        case .magenta:
            return "Magenta"
        }
    }

    public static func fromStored(_ raw: String?, default fallback: FlexokiHue) -> FlexokiHue {
        guard let raw, let value = FlexokiHue(rawValue: raw) else { return fallback }
        return value
    }
}

public struct ReaderAppearanceSettings: Equatable, Sendable {
    public static let fontSizeRange = 14.0 ... 30.0
    public static let lineSpacingRange = 2.0 ... 16.0
    public static let lineWidthRange = 260.0 ... 980.0

    public var fontSize: Double
    public var fontStyle: ReaderFontStyle
    public var lineSpacing: Double
    public var justification: ReaderJustification
    public var background: ReaderBackground
    public var primaryAccent: FlexokiHue
    public var secondaryAccent: FlexokiHue
    public var lineWidth: Double

    public init(
        fontSize: Double = 19,
        fontStyle: ReaderFontStyle = .newYork,
        lineSpacing: Double = 8,
        justification: ReaderJustification = .leading,
        background: ReaderBackground = .paper,
        primaryAccent: FlexokiHue = .blue,
        secondaryAccent: FlexokiHue = .purple,
        lineWidth: Double = 820
    ) {
        self.fontSize = fontSize
        self.fontStyle = fontStyle
        self.lineSpacing = lineSpacing
        self.justification = justification
        self.background = background
        self.primaryAccent = primaryAccent
        self.secondaryAccent = secondaryAccent
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
    public enum Status: String, Codable, Sendable {
        case queued = "queued"
        case processing = "processing"
        case failed = "failed"
        case completed = "completed"
        case dismissed = "dismissed"
    }

    public enum Kind: String, Codable, Sendable {
        case url = "url"
        case text = "text"
        case markdown = "markdown"
        case hydrate = "hydrate"
        case hydrateText = "hydrateText"
        case pdf = "pdf"
        case website = "website"
        case hydrateWebsite = "hydrateWebsite"
    }

    public let id: UUID
    public let kind: Kind
    public let payload: String
    public let createdAt: Date
    public let status: Status
    public let claimedAt: Date?
    public let attemptCount: Int
    public let lastError: String?

    public init(
        kind: Kind,
        payload: String,
        id: UUID = UUID(),
        createdAt: Date = .now,
        status: Status = .queued,
        claimedAt: Date? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.status = status
        self.claimedAt = claimedAt
        self.attemptCount = attemptCount
        self.lastError = lastError
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

public struct TextHydrationPayload: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var rawSourceText: String
    public var rawSourceMode: String?
    public var title: String

    public init(itemID: UUID, rawSourceText: String, rawSourceMode: String?, title: String) {
        self.itemID = itemID
        self.rawSourceText = rawSourceText
        self.rawSourceMode = rawSourceMode
        self.title = title
    }
}

public struct WebsiteHydrationPayload: Codable, Equatable, Sendable {
    public var itemID: UUID

    public init(itemID: UUID) {
        self.itemID = itemID
    }
}
