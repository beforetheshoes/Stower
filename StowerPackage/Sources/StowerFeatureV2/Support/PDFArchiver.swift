import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Places the original PDF bytes and rasterized page images for a saved
/// item on disk under the shared `StowerArchive/{itemID}/` directory.
///
/// Reader mode for PDFs is "pages as images": at ingestion time each page
/// is rasterized to `pdf-page-N.jpg` and the reader's structured HTML
/// emits one `<figure>` per page. This preserves the original visual
/// design (logos, colors, tables, merged cells, everything) without
/// trying to reconstruct layout as semantic markup. The `document.pdf`
/// original is kept for the reader's "Show Original PDF" toolbar action.
enum PDFArchiver {
    /// Filename used for the original PDF bytes. A single file per item is
    /// sufficient — PDF items don't carry extra assets.
    static let pdfFilename = "document.pdf"

    /// Filename prefix for rasterized page images. Stable so the reader's
    /// structured-HTML symlink step can find them by pattern.
    static let pageImagePrefix = "pdf-page-"

    /// Absolute URL of the archived PDF for a given item (may not exist).
    static func pdfURL(for itemID: UUID) -> URL {
        AssetArchiver.archiveDirectory(for: itemID)
            .appendingPathComponent(pdfFilename)
    }

    /// Absolute URL of a rasterized page image for a given item.
    static func pageImageURL(for itemID: UUID, pageIndex: Int) -> URL {
        AssetArchiver.archiveDirectory(for: itemID)
            .appendingPathComponent(pageImageFilename(pageIndex: pageIndex))
    }

    /// Filename (no directory) for a rasterized page image.
    static func pageImageFilename(pageIndex: Int) -> String {
        "\(pageImagePrefix)\(pageIndex).jpg"
    }

    /// Whether an archived PDF file exists on disk for the given item.
    static func pdfExists(for itemID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: pdfURL(for: itemID).path)
    }

    /// Copies a PDF file from `source` into the item's archive directory,
    /// replacing any existing `document.pdf`. The caller is responsible for
    /// deleting the source (which typically lives in the temporary directory
    /// or the shared App Group `PendingPDFs/` folder) after a successful copy.
    static func archivePDF(from source: URL, itemID: UUID) throws {
        let destination = pdfURL(for: itemID)
        try ensureArchiveDirectoryExists(for: itemID)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Encodes a `CGImage` as a JPEG and writes it to the archive directory
    /// for a given item/page. Uses ImageIO directly so the writer is
    /// available on both iOS and macOS without UIKit/AppKit. JPEG at
    /// quality 0.85 produces ~200–500 KB for a letter-size page at 2x
    /// scale, which renders sharp on retina displays without bloating
    /// storage.
    static func archivePageImage(
        _ image: CGImage,
        for itemID: UUID,
        pageIndex: Int,
        jpegQuality: CGFloat = 0.85
    ) throws {
        try ensureArchiveDirectoryExists(for: itemID)
        let destination = pageImageURL(for: itemID, pageIndex: pageIndex)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ArchiveError.imageDestinationCreationFailed
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ArchiveError.imageDestinationFinalizeFailed
        }
    }

    /// Removes the archived PDF and every `pdf-page-N.jpg` file for an
    /// item, if present. Safe to call on items that never had a PDF
    /// archived. Called from the permanent-delete path alongside
    /// `AssetArchiver.deleteArchive`.
    static func deletePDF(for itemID: UUID) {
        try? FileManager.default.removeItem(at: pdfURL(for: itemID))
        deletePageImages(for: itemID)
    }

    /// Removes every `pdf-page-N.jpg` file for an item. Useful when
    /// re-rasterizing — ensures stale page images from a previous
    /// ingestion don't leak into the new reader output.
    static func deletePageImages(for itemID: UUID) {
        let dir = AssetArchiver.archiveDirectory(for: itemID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix(pageImagePrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Returns every archived `pdf-page-N.jpg` URL for an item, sorted by
    /// numeric page index. Used by the reader's structured-HTML server to
    /// symlink page images into the per-view scratch dir so they can be
    /// served as relative-path assets alongside `index.html`.
    static func pageImageURLs(for itemID: UUID) -> [URL] {
        let dir = AssetArchiver.archiveDirectory(for: itemID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent.hasPrefix(pageImagePrefix) }
            .sorted { lhs, rhs in
                pageIndex(from: lhs) < pageIndex(from: rhs)
            }
    }

    /// Parses the numeric index out of a `pdf-page-N.jpg` URL for sorting.
    /// Returns `Int.max` for any filename that doesn't match, which pushes
    /// malformed entries to the end so they don't disrupt legitimate
    /// ordering.
    private static func pageIndex(from url: URL) -> Int {
        let name = url.lastPathComponent
        guard name.hasPrefix(pageImagePrefix) else { return .max }
        let stripped = name
            .dropFirst(pageImagePrefix.count)
            .prefix(while: { $0.isNumber })
        return Int(stripped) ?? .max
    }

    private static func ensureArchiveDirectoryExists(for itemID: UUID) throws {
        try FileManager.default.createDirectory(
            at: AssetArchiver.archiveDirectory(for: itemID),
            withIntermediateDirectories: true
        )
    }

    enum ArchiveError: Error {
        case imageDestinationCreationFailed
        case imageDestinationFinalizeFailed
    }
}
