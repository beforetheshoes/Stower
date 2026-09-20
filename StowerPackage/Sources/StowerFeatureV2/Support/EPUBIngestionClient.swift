import CryptoKit
import Dependencies
import Foundation
import OSLog
import StowerData
import SwiftSoup
import ZIPFoundation

private let kEPUBIngestLog = Logger(
    subsystem: "com.ryanleewilliams.stower",
    category: "EPUBIngest"
)

public enum EPUBIngestionError: Error, Equatable, LocalizedError {
    case unreadable
    case missingPackage
    case protectedContent
    case emptyBook
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "The EPUB couldn't be opened. It may be corrupted or not a valid EPUB."
        case .missingPackage:
            "The EPUB has no package document, so its chapters can't be found."
        case .protectedContent:
            "This EPUB is copy-protected (DRM), so its text can't be read."
        case .emptyBook:
            "The EPUB contains no readable chapters."
        case .tooLarge:
            "The EPUB is larger than Stower can import."
        }
    }
}

/// Ingests a local `.epub` file into an `IngestionResult` for the reader.
///
/// An EPUB is a zip of XHTML chapters plus a package document that lists
/// them in reading order. Each chapter goes through the same block parser
/// web articles use, and the chapters are joined into one reader document,
/// so a book gets everything an article gets: themes, progress, search,
/// narration, summaries. Images are copied out of the zip into the item's
/// archive directory and referenced by filename (see `EPUBBookArchiver`).
public struct EPUBIngestionClient: Sendable {
    public var ingest: @Sendable (URL) async throws -> IngestionResult

    public init(ingest: @escaping @Sendable (URL) async throws -> IngestionResult) {
        self.ingest = ingest
    }

    public static let failing = EPUBIngestionClient { _ in
        throw EPUBIngestionError.unreadable
    }

    public static let live = EPUBIngestionClient { url in
        try await EPUBIngestor.ingest(url: url)
    }
}

enum EPUBIngestor {
    /// Ceiling on the bytes read out of the zip across one import. Entries
    /// are inflated in memory one at a time, so this bounds the work a
    /// crafted archive can cause rather than peak memory.
    private static let maxTotalBytes: UInt64 = 1024 * 1_048_576
    private static let maxDocumentBytes: UInt64 = 32 * 1_048_576
    private static let maxImageBytes: UInt64 = 32 * 1_048_576

    static func ingest(url: URL) async throws -> IngestionResult {
        let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
        let hexHash = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        let canonicalURL = SavedItem.importedBookURLPrefix + hexHash
        let itemID = StowerRepository.stableItemID(from: canonicalURL)

        let reader: EPUBZipReader
        do {
            reader = try EPUBZipReader(url: url, maxTotalBytes: maxTotalBytes)
        } catch {
            throw EPUBIngestionError.unreadable
        }

        if let encryption = try reader.text(at: "META-INF/encryption.xml", limit: maxDocumentBytes),
           try EPUBPackageParser.hasEncryptedContent(encryptionXML: encryption) {
            throw EPUBIngestionError.protectedContent
        }

        guard let container = try reader.text(at: "META-INF/container.xml", limit: maxDocumentBytes),
              let opfPath = try EPUBPackageParser.packagePath(containerXML: container),
              let opf = try reader.text(at: opfPath, limit: maxDocumentBytes)
        else {
            throw EPUBIngestionError.missingPackage
        }
        let package = try EPUBPackageParser.parse(opfXML: opf, opfPath: opfPath)
        guard !package.spine.isEmpty else {
            throw EPUBIngestionError.emptyBook
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = package.title ?? (fallbackTitle.isEmpty ? "Untitled Book" : fallbackTitle)
        kEPUBIngestLog.notice(
            "Ingesting EPUB \"\(title, privacy: .public)\" (\(package.spine.count, privacy: .public) spine items)"
        )

        // Re-importing the same file must not leave images from an earlier
        // pass next to the new ones.
        EPUBBookArchiver.deleteImages(for: itemID)

        var images = EPUBImageStore(reader: reader, itemID: itemID, maxImageBytes: maxImageBytes)
        let labels = chapterLabels(package: package, reader: reader)

        var blocks = [ReaderBlock]()
        for chapter in package.spine {
            try Task.checkCancellation()
            guard let xhtml = try reader.text(at: chapter.path, limit: maxDocumentBytes) else {
                kEPUBIngestLog.error("Spine item missing from zip: \(chapter.path, privacy: .public)")
                continue
            }
            var chapterBlocks = try parseChapter(xhtml: xhtml, path: chapter.path, images: &images)
            guard !chapterBlocks.isEmpty else { continue }

            if !startsWithHeading(chapterBlocks) {
                if let label = labels[chapter.path], label.caseInsensitiveCompare(title) != .orderedSame {
                    chapterBlocks.insert(.heading(level: 2, inlines: [.text(label)]), at: 0)
                } else if !blocks.isEmpty {
                    chapterBlocks.insert(.horizontalRule, at: 0)
                }
            }
            blocks.append(contentsOf: chapterBlocks)
        }

        // The reader page already shows the title above the text, so a title
        // page that only repeats it would print it twice.
        if case .heading(_, let inlines)? = blocks.first,
           ReaderTextLayoutSupport.inlinePlainText(from: inlines)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(title) == .orderedSame {
            blocks.removeFirst()
        }

        guard !blocks.isEmpty else {
            throw EPUBIngestionError.emptyBook
        }

        let heroImageURL = package.coverImagePath
            .flatMap { images.archiveCover(path: $0) }
            .map { "\(WebsiteArchiveUnpacker.heroArchiveURLScheme):\($0)" }

        let document = ReaderDocument(
            title: title,
            blocks: blocks,
            version: 1,
            sourceURL: nil,
            canonicalURL: canonicalURL
        )
        let plainText = plainTextFromBlocks(blocks)
        let summary = package.summary.flatMap { try? SwiftSoup.parse($0).text() }.map(cleanText)
        let excerpt = [summary, String(plainText.prefix(220))]
            .compactMap { $0 }
            .first { !$0.isEmpty }

        var seenSources = Set<String>()
        let media = blocks.compactMap { block -> MediaDescriptor? in
            guard case .figure(let descriptor) = block,
                  seenSources.insert(descriptor.sourceURL).inserted
            else { return nil }
            return descriptor
        }

        let result = IngestionResult(
            title: title,
            sourceURL: nil,
            canonicalURL: canonicalURL,
            excerpt: excerpt.map { String($0.prefix(400)) },
            author: package.author,
            publishedAt: package.publishedAt,
            siteName: package.publisher,
            heroImageURL: heroImageURL,
            readingTimeMinutes: estimateReadingTime(text: plainText),
            hasRichMedia: !media.isEmpty,
            renderFormat: .structuredV1,
            processingState: .ready,
            processingError: nil,
            document: document,
            plainText: plainText,
            media: media,
            embeds: [],
            sourceHTML: ""
        )
        return result
    }

    // MARK: - Chapters

    static func parseChapter(
        xhtml: String,
        path: String,
        images: inout EPUBImageStore
    ) throws -> [ReaderBlock] {
        let document = try SwiftSoup.parse(xhtml)
        guard let body = document.body() else { return [] }

        // Cover pages usually wrap their image in an `<svg>` so it scales to
        // the viewport. The block parser drops SVG, so lift the image out.
        for svg in try body.select("svg").array() {
            guard let image = try svg.select("image").first() else { continue }
            let href = try image.attr("xlink:href").isEmpty ? image.attr("href") : image.attr("xlink:href")
            let replacement = try document.createElement("img")
            try replacement.attr("src", href)
            try svg.replaceWith(replacement)
        }

        for image in try body.select("img").array() {
            let source = try image.attr("src")
            guard let resolved = EPUBPath.resolve(source, relativeTo: path),
                  let filename = images.archive(path: resolved)
            else {
                try image.remove()
                continue
            }
            try image.attr("src", EPUBBookArchiver.markerURL(filename: filename))
            try image.removeAttr("srcset")
        }

        let baseURL = URL(string: "stower://epub/")!
        let parsed = try parseBlocks(root: body, baseURL: baseURL)
        let itemID = images.itemID
        return parsed.blocks.map { block in
            guard case .figure(var media) = block,
                  let filename = EPUBBookArchiver.imageFilename(fromMarker: media.sourceURL)
            else { return block }
            media.localURL = EPUBBookArchiver.imageURL(for: itemID, filename: filename).path
            return .figure(media: media)
        }
    }

    private static func startsWithHeading(_ blocks: [ReaderBlock]) -> Bool {
        // A chapter often opens with a decorative image before its title.
        for block in blocks.prefix(3) {
            if case .heading = block {
                return true
            }
        }
        return false
    }

    private static func chapterLabels(package: EPUBBookPackage, reader: EPUBZipReader) -> [String: String] {
        if let navPath = package.navigationPath,
           let nav = try? reader.text(at: navPath, limit: maxDocumentBytes),
           let labels = try? EPUBPackageParser.navigationLabels(navXHTML: nav, navPath: navPath),
           !labels.isEmpty {
            return labels
        }
        if let ncxPath = package.ncxPath,
           let ncx = try? reader.text(at: ncxPath, limit: maxDocumentBytes),
           let labels = try? EPUBPackageParser.ncxLabels(ncxXML: ncx, ncxPath: ncxPath) {
            return labels
        }
        return [:]
    }
}

// MARK: - Zip access

/// Random access to the entries of an EPUB zip. Entries are read straight
/// into memory, never unpacked to disk, so entry paths are only ever used
/// as lookup keys.
final class EPUBZipReader {
    private let archive: Archive
    private let entries: [String: Entry]
    private let lowercasedEntries: [String: Entry]
    private var remainingBytes: UInt64

    init(url: URL, maxTotalBytes: UInt64) throws {
        archive = try Archive(url: url, accessMode: .read)
        var entries = [String: Entry]()
        var lowercased = [String: Entry]()
        for entry in archive where entry.type == .file {
            entries[entry.path] = entry
            lowercased[entry.path.lowercased()] = entry
        }
        self.entries = entries
        self.lowercasedEntries = lowercased
        self.remainingBytes = maxTotalBytes
    }

    func data(at path: String, limit: UInt64) throws -> Data? {
        // Some producers write manifest hrefs in a different case than the
        // zip entry they name.
        guard let entry = entries[path] ?? lowercasedEntries[path.lowercased()] else { return nil }
        guard entry.uncompressedSize <= limit else { return nil }
        guard entry.uncompressedSize <= remainingBytes else {
            throw EPUBIngestionError.tooLarge
        }
        remainingBytes -= entry.uncompressedSize
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    func text(at path: String, limit: UInt64) throws -> String? {
        guard let data = try data(at: path, limit: limit) else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        // Latin-1 maps every byte, so a chapter in a legacy encoding still
        // yields text instead of failing the import.
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1)
    }
}

// MARK: - Images

/// Copies images out of the zip into the item's archive directory, once per
/// zip path, and hands back the archived filename.
struct EPUBImageStore {
    let reader: EPUBZipReader
    let itemID: UUID
    let maxImageBytes: UInt64
    private var filenamesByPath = [String: String]()
    private var nextIndex = 0

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "svg", "avif", "bmp", "tif", "tiff",
    ]

    init(reader: EPUBZipReader, itemID: UUID, maxImageBytes: UInt64) {
        self.reader = reader
        self.itemID = itemID
        self.maxImageBytes = maxImageBytes
    }

    mutating func archive(path: String) -> String? {
        if let existing = filenamesByPath[path] {
            return existing
        }
        guard let fileExtension = Self.imageExtension(for: path) else { return nil }
        let filename = "\(EPUBBookArchiver.imagePrefix)\(nextIndex).\(fileExtension)"
        guard write(path: path, filename: filename) else { return nil }
        nextIndex += 1
        filenamesByPath[path] = filename
        return filename
    }

    /// Archives the cover under a fixed name so the library row can find it
    /// without reading the document.
    func archiveCover(path: String) -> String? {
        guard let fileExtension = Self.imageExtension(for: path) else { return nil }
        let filename = "\(EPUBBookArchiver.imagePrefix)cover.\(fileExtension)"
        return write(path: path, filename: filename) ? filename : nil
    }

    private func write(path: String, filename: String) -> Bool {
        guard let data = try? reader.data(at: path, limit: maxImageBytes), !data.isEmpty else {
            return false
        }
        do {
            try EPUBBookArchiver.archiveImage(data, filename: filename, itemID: itemID)
            return true
        } catch {
            kEPUBIngestLog.error("Failed to archive image \(path, privacy: .public)")
            return false
        }
    }

    private static func imageExtension(for path: String) -> String? {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(fileExtension) ? fileExtension : nil
    }
}

// MARK: - Dependency key

private enum EPUBIngestionClientKey: DependencyKey {
    static var liveValue: EPUBIngestionClient { .live }
    static var testValue: EPUBIngestionClient { .failing }
}

extension DependencyValues {
    public var epubIngestionClient: EPUBIngestionClient {
        get { self[EPUBIngestionClientKey.self] }
        set { self[EPUBIngestionClientKey.self] = newValue }
    }
}
