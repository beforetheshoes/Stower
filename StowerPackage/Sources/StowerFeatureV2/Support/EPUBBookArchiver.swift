import Foundation

/// On-disk storage for an imported EPUB: the original file plus the images
/// its chapters reference. Everything lives in the item's archive directory
/// (`StowerArchive/{itemID}/`) alongside the other per-item payloads.
///
/// Chapter images are written as `epub-img-N.ext` and referenced from the
/// reader document by the marker URL `stower://epub-image/epub-img-N.ext`.
/// The marker carries only the filename, so the document stays valid when
/// the app container moves (restore, reinstall) or the document reaches
/// another device.
enum EPUBBookArchiver {
    static let bookFilename = "book.epub"
    static let imagePrefix = "epub-img-"
    static let imageMarkerPrefix = "stower://epub-image/"

    static func bookURL(for itemID: UUID) -> URL {
        AssetArchiver.archiveDirectory(for: itemID).appendingPathComponent(bookFilename)
    }

    static func imageURL(for itemID: UUID, filename: String) -> URL {
        AssetArchiver.archiveDirectory(for: itemID).appendingPathComponent(filename)
    }

    static func markerURL(filename: String) -> String {
        imageMarkerPrefix + filename
    }

    /// The archived filename a marker URL points at, or nil when `sourceURL`
    /// is not an EPUB image marker. Rejects anything that is not a bare
    /// `epub-img-` filename so a crafted document cannot reach other files.
    static func imageFilename(fromMarker sourceURL: String) -> String? {
        guard sourceURL.hasPrefix(imageMarkerPrefix) else { return nil }
        let filename = String(sourceURL.dropFirst(imageMarkerPrefix.count))
        guard filename.hasPrefix(imagePrefix),
              !filename.contains("/"),
              !filename.contains("..")
        else { return nil }
        return filename
    }

    static func archiveBook(from source: URL, itemID: UUID) throws {
        try ensureArchiveDirectoryExists(for: itemID)
        let destination = bookURL(for: itemID)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func archiveImage(_ data: Data, filename: String, itemID: UUID) throws {
        try ensureArchiveDirectoryExists(for: itemID)
        try data.write(to: imageURL(for: itemID, filename: filename), options: .atomic)
    }

    static func deleteImages(for itemID: UUID) {
        for url in imageURLs(for: itemID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func imageURLs(for itemID: UUID) -> [URL] {
        let directory = AssetArchiver.archiveDirectory(for: itemID)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(imagePrefix) }
    }

    /// Symlinks the item's chapter images into `targetDir` so the reader's
    /// local server can serve them next to `index.html`. Returns the number
    /// of links created.
    @discardableResult
    static func symlinkImages(for itemID: UUID, into targetDir: URL) -> Int {
        var count = 0
        for source in imageURLs(for: itemID) {
            let link = targetDir.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: link)
            if (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)) != nil {
                count += 1
            }
        }
        return count
    }

    private static func ensureArchiveDirectoryExists(for itemID: UUID) throws {
        try FileManager.default.createDirectory(
            at: AssetArchiver.archiveDirectory(for: itemID),
            withIntermediateDirectories: true
        )
    }
}
