import CryptoKit
import Foundation
import OSLog
import StowerData

private let kWebsiteImportLog = Logger(
    subsystem: "com.ryanleewilliams.stower",
    category: "WebsiteImport"
)

/// Shared entry points for bringing a user-uploaded website zip into the
/// library. Used by both the in-app file importer (inline, foreground) and
/// the ingestion job processor (on sync hydration or after share-extension
/// enqueue). Keeping the implementation here lets the two call sites share
/// the same size caps, unpack rules, and title-resolution behaviour.
enum WebsiteImportService {
    /// Hard ceiling on the compressed zip size users can import.
    static let maxCompressedBytes: Int64 = 200 * 1_048_576
    /// Ceiling on total uncompressed bytes during unpack. Generous relative
    /// to the compressed cap so legitimately compressible sites pass, but
    /// bounded to defuse zip bombs.
    static let maxUncompressedBytes: Int64 = 400 * 1_048_576

    enum ImportError: Error, LocalizedError {
        case sizeCapExceeded(Int64)
        /// The zip bytes pulled from the CloudKit-synced archive table
        /// don't match the origin device's stored SHA-256. Typically this
        /// means the CKAsset hasn't finished downloading and we're reading
        /// a stale/partial blob. The hydrator should skip and try again on
        /// the next sync tick instead of unpacking broken data.
        case incompleteAsset(expected: String, received: String, byteCount: Int)

        var errorDescription: String? {
            switch self {
            case .sizeCapExceeded(let cap):
                return "The website archive is larger than the \(cap / 1_048_576) MB limit."
            case let .incompleteAsset(expected, received, byteCount):
                return "Website archive is still downloading (\(byteCount) bytes, expected sha256 \(expected.prefix(8)), got \(received.prefix(8)))."
            }
        }
    }

    /// Runs the full import for a zip that already lives on disk:
    ///   * Reads and hashes the bytes.
    ///   * Creates a `.webView` item with a filename-derived placeholder title.
    ///   * Unpacks into the item's archive directory.
    ///   * Updates the title from the extracted `<title>` tag when present.
    ///   * Persists the zip bytes into the CloudKit-synced archive table.
    /// Returns the resulting item so the caller can open it immediately.
    static func importWebsite(
        zipURL: URL,
        repository: StowerRepository
    ) async throws -> SavedItem {
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= maxCompressedBytes else {
            throw ImportError.sizeCapExceeded(maxCompressedBytes)
        }

        let zipData = try Data(contentsOf: zipURL)
        let digest = SHA256.hash(data: zipData)
        let sha256 = digest.map { String(format: "%02x", $0) }.joined()

        let filename = zipURL.lastPathComponent
        let fallbackTitle = zipURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // Unpack into a scratch staging directory FIRST, before the DB row
        // exists. This lets us create the item with the final title and
        // hero image in a single `createItemFromIngestion` call, instead of
        // a create→update dance. The update path uses raw SQL that bypasses
        // SQLiteData's per-field change tracking, so a CloudKit echo of the
        // original create would revert our updated metadata — observed in
        // the logs as `Metadata updated title=Archive hero=<nil>` even
        // though the unpacker extracted correct values. Single-create
        // threads the real values through SQLiteData's sync tracking and
        // uploads them as the authoritative first version.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowerWebsiteStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let unpack = try WebsiteArchiveUnpacker.unpack(
            zipAt: zipURL,
            into: staging,
            maxUncompressedBytes: maxUncompressedBytes
        )

        let stagedRelativeIndex = WebsiteArchiveUnpacker.relativePath(
            of: unpack.indexURL,
            in: staging
        ) ?? "<unknown>"
        kWebsiteImportLog.info(
            "Unpacked entries=\(unpack.entryCount, privacy: .public) index=\(stagedRelativeIndex, privacy: .public) title=\(unpack.title ?? "<nil>", privacy: .public) hero=\(unpack.heroImageRelativePath ?? "<nil>", privacy: .public) size=\(fileSize, privacy: .public)"
        )

        let resolvedTitle = unpack.title ?? fallbackTitle
        let heroURL = unpack.heroImageRelativePath.map {
            "\(WebsiteArchiveUnpacker.heroArchiveURLScheme):\($0)"
        }

        let item = try await repository.createItemFromIngestion(
            .importedWebsite(
                title: resolvedTitle,
                filename: filename,
                heroImageURL: heroURL
            )
        )
        kWebsiteImportLog.info(
            "Created item \(item.id.uuidString, privacy: .public) title=\(item.title, privacy: .public) hero=\(item.heroImageURL ?? "<nil>", privacy: .public)"
        )

        // Move the staged archive to its permanent location keyed by the
        // just-assigned item ID. Same-filesystem renames are cheap even for
        // large archives.
        let archiveDir = AssetArchiver.archiveDirectory(for: item.id)
        if FileManager.default.fileExists(atPath: archiveDir.path) {
            try FileManager.default.removeItem(at: archiveDir)
        }
        try FileManager.default.createDirectory(
            at: archiveDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: staging, to: archiveDir)

        try await repository.saveWebsiteArchive(item.id, zipData, sha256, filename)
        kWebsiteImportLog.info(
            "Import complete \(item.id.uuidString, privacy: .public)"
        )
        return item
    }

    /// Receive-side unpack. The zip bytes and the item's title/hero come
    /// in from CloudKit; all we need to do here is materialize the unpacked
    /// archive on disk and tell the local content table that this item is
    /// a `.webView` archive that's ready to read. The CloudKit-synced
    /// `SavedItemSyncTable` row doesn't carry `renderFormat`, which lives
    /// in the local-only content table — so without this local write the
    /// reader would keep treating the item as `.structuredV1` and the
    /// Download button would loop back to the same prompt forever.
    ///
    /// Defensive flow:
    ///   1. Verify the blob we read locally hashes to the stored SHA-256.
    ///      Mismatches mean the CKAsset is mid-download — throw and let
    ///      the next sync tick retry instead of unpacking garbage.
    ///   2. Write the zip and unpack into a scratch staging directory, not
    ///      directly into the archive directory. Mid-unpack failures are
    ///      contained to the scratch area and can't leave a partial archive
    ///      in its final location.
    ///   3. Only once the unpack reports success, atomically swap the
    ///      staged tree into the permanent archive directory.
    ///   4. Hydrate the local content row so the reader recognises the
    ///      item as a renderable webView archive.
    static func hydrateWebsite(
        itemID: UUID,
        archive: WebsiteArchiveBytes,
        repository: StowerRepository
    ) async throws {
        let received = SHA256.hash(data: archive.zipData)
            .map { String(format: "%02x", $0) }
            .joined()
        if !archive.sha256.isEmpty, received != archive.sha256 {
            throw ImportError.incompleteAsset(
                expected: archive.sha256,
                received: received,
                byteCount: archive.zipData.count
            )
        }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowerWebsiteHydrate", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: scratchRoot)
        try FileManager.default.createDirectory(
            at: scratchRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let filename = archive.originalFilename.isEmpty
            ? "site.zip"
            : archive.originalFilename
        let zipURL = scratchRoot.appendingPathComponent(filename)
        try archive.zipData.write(to: zipURL, options: .atomic)

        let stagingDir = scratchRoot.appendingPathComponent("unpacked", isDirectory: true)
        _ = try WebsiteArchiveUnpacker.unpack(
            zipAt: zipURL,
            into: stagingDir,
            maxUncompressedBytes: maxUncompressedBytes
        )

        let archiveDir = AssetArchiver.archiveDirectory(for: itemID)
        if FileManager.default.fileExists(atPath: archiveDir.path) {
            try FileManager.default.removeItem(at: archiveDir)
        }
        try FileManager.default.createDirectory(
            at: archiveDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: stagingDir, to: archiveDir)

        try await repository.hydrateItemContent(
            itemID,
            .importedWebsite(
                title: archive.originalFilename,
                filename: archive.originalFilename
            )
        )
    }
}
