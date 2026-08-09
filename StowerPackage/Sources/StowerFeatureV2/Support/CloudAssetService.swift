import Dependencies
import Foundation
import OSLog
import PDFKit
import StowerData

private let kAssetServiceLogger = Logger(subsystem: "com.ryanleewilliams.stower", category: "CloudAssetService")

public enum CloudAssetServiceError: Error, Equatable, LocalizedError {
    case missingLocalFile
    case missingManifest
    case integrityFailure
    case unreadablePDF

    public var errorDescription: String? {
        switch self {
        case .missingLocalFile:
            "The file to upload no longer exists on this device."
        case .missingManifest:
            "This item has no copy stored in iCloud yet."
        case .integrityFailure:
            "The downloaded file was incomplete. It will be retried."
        case .unreadablePDF:
            "The downloaded PDF could not be opened."
        }
    }
}

/// Upload, download, and migration flows for the app-managed CloudKit asset
/// store. This is the only place that composes `CloudAssetClient` (CloudKit),
/// `ItemStorageClient` (SQLite state), and the on-disk archivers.
public enum CloudAssetService {
    /// Where a freshly imported website zip waits for its upload job. Deleted
    /// once the upload is confirmed; offload is blocked until then.
    static func pendingUploadZipURL(for itemID: UUID) -> URL {
        AssetArchiver.archiveDirectory(for: itemID)
            .appendingPathComponent("pending-upload.zip")
    }

    // MARK: Upload

    /// Uploads an item's heavy payload and records the synced manifest.
    /// Idempotent: record names are content-addressed and re-upserting the
    /// manifest replaces the previous row for (item, kind).
    public static func upload(payload: AssetJobPayload) async throws {
        @Dependency(\.cloudAssetClient)
        var cloudAssetClient
        @Dependency(\.itemStorageClient)
        var itemStorageClient
        @Dependency(\.cloudSyncClient)
        var cloudSyncClient
        @Dependency(\.uuid)
        var uuid

        let fileURL: URL
        var cleanupAfterUpload: URL?
        switch payload.kind {
        case .pdf:
            fileURL = PDFArchiver.pdfURL(for: payload.itemID)
        case .websiteZip:
            fileURL = pendingUploadZipURL(for: payload.itemID)
            cleanupAfterUpload = fileURL
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // The local source is gone (e.g. re-installed device). Mark the
            // state so eviction stays blocked, then surface the failure.
            try? await itemStorageClient.setUploadState(payload.itemID, "failed")
            throw CloudAssetServiceError.missingLocalFile
        }

        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let sha256 = ArticleCapturePackage.sha256(data)
        let manifest = AssetManifest(
            id: uuid(),
            itemID: payload.itemID,
            kind: payload.kind,
            recordName: AssetManifest.makeRecordName(
                kind: payload.kind,
                itemID: payload.itemID,
                sha256: sha256
            ),
            sha256: sha256,
            byteCount: data.count,
            originalFilename: payload.originalFilename
                ?? fileURL.lastPathComponent
        )

        do {
            try await cloudAssetClient.upload(manifest, fileURL)
            guard try await cloudAssetClient.exists(manifest.recordName) else {
                throw CloudAssetError.transient("Upload not visible after save")
            }
        } catch {
            if case CloudAssetError.quotaExceeded = error {
                try? await itemStorageClient.setUploadState(payload.itemID, "failed")
            }
            throw error
        }

        try await itemStorageClient.upsertManifest(manifest)
        try await itemStorageClient.setUploadState(payload.itemID, "uploaded")
        if let cleanupAfterUpload {
            try? FileManager.default.removeItem(at: cleanupAfterUpload)
        }
        await cloudSyncClient.scheduleSendChanges()
        kAssetServiceLogger.info("Uploaded \(manifest.recordName, privacy: .public) (\(manifest.byteCount) bytes)")
    }

    // MARK: Migration

    /// Moves one legacy website zip out of the SyncEngine BLOB table into the
    /// asset store. Strictly upload → verify → replace: the `zipData` row is
    /// only deleted (which propagates to CloudKit) after the asset record is
    /// confirmed to exist.
    public static func migrateWebsiteZip(itemID: UUID, repository: StowerRepository) async throws {
        @Dependency(\.cloudAssetClient)
        var cloudAssetClient
        @Dependency(\.itemStorageClient)
        var itemStorageClient
        @Dependency(\.cloudSyncClient)
        var cloudSyncClient
        @Dependency(\.uuid)
        var uuid

        guard let archive = try await repository.loadWebsiteArchive(itemID) else {
            // Nothing to migrate (already migrated, or the row never finished
            // syncing to this device). Not an error.
            return
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowerAssetMigration-\(uuid().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try archive.zipData.write(to: scratch, options: .atomic)

        let sha256 = archive.sha256.isEmpty
            ? ArticleCapturePackage.sha256(archive.zipData)
            : archive.sha256
        let manifest = AssetManifest(
            id: uuid(),
            itemID: itemID,
            kind: .websiteZip,
            recordName: AssetManifest.makeRecordName(
                kind: .websiteZip,
                itemID: itemID,
                sha256: sha256
            ),
            sha256: sha256,
            byteCount: archive.zipData.count,
            originalFilename: archive.originalFilename
        )

        try await cloudAssetClient.upload(manifest, scratch)
        guard try await cloudAssetClient.exists(manifest.recordName) else {
            throw CloudAssetError.transient("Upload not visible after save")
        }
        try await itemStorageClient.replaceWebsiteArchiveWithManifest(manifest)
        await cloudSyncClient.scheduleSendChanges()
        kAssetServiceLogger.info("Migrated website zip for \(itemID, privacy: .public) to asset store")
    }

    // MARK: Download / restore

    /// Downloads an offloaded item's payload and reinstalls it locally.
    /// Sources, in order: asset store (PDF, website zip), the legacy zip sync
    /// row, and — for interactive captures — the chunk rows already in the
    /// local database (which needs no network at all).
    public static func restore(itemID: UUID, repository: StowerRepository) async throws {
        @Dependency(\.itemStorageClient)
        var itemStorageClient
        @Dependency(\.articleSaveClient)
        var articleSaveClient

        try await repository.updateLocalContentStatus(itemID, "downloading", nil)
        do {
            if let manifest = try await itemStorageClient.manifest(itemID, .pdf) {
                try await restorePDF(manifest: manifest, repository: repository)
            } else if let manifest = try await itemStorageClient.manifest(itemID, .websiteZip) {
                try await restoreWebsiteZip(manifest: manifest, repository: repository)
            } else if let archive = try await repository.loadWebsiteArchive(itemID) {
                // Legacy path: the zip still lives in the sync table.
                try await WebsiteImportService.hydrateWebsite(
                    itemID: itemID,
                    archive: archive,
                    repository: repository
                )
            } else if let info = try await itemStorageClient.storageInfo(itemID),
                      info.hasCaptureManifest,
                      let sourceURL = try await repository.loadItem(itemID)?.sourceURL,
                      let url = URL(string: sourceURL) {
                // Interactive capture: reinstall from local chunk rows.
                _ = try await articleSaveClient.hydrate(itemID, url)
                try await repository.updateLocalContentStatus(itemID, "available", nil)
            } else {
                throw CloudAssetServiceError.missingManifest
            }
            try await itemStorageClient.setOffloaded(itemID, false)
        } catch {
            try? await repository.updateLocalContentStatus(itemID, "failed", restoreFailureMessage(error))
            throw error
        }
    }

    private static func restorePDF(manifest: AssetManifest, repository: StowerRepository) async throws {
        @Dependency(\.cloudAssetClient)
        var cloudAssetClient
        @Dependency(\.uuid)
        var uuid

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowerAssetDownload-\(uuid().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try await cloudAssetClient.download(manifest.recordName, scratch)
        let data = try Data(contentsOf: scratch, options: .mappedIfSafe)
        guard ArticleCapturePackage.sha256(data) == manifest.sha256 else {
            throw CloudAssetServiceError.integrityFailure
        }

        try PDFArchiver.archivePDF(from: scratch, itemID: manifest.itemID)
        try rerasterizePages(itemID: manifest.itemID, pdfURL: scratch)
        try await repository.updateLocalContentStatus(manifest.itemID, "available", nil)
    }

    private static func restoreWebsiteZip(manifest: AssetManifest, repository: StowerRepository) async throws {
        @Dependency(\.cloudAssetClient)
        var cloudAssetClient
        @Dependency(\.uuid)
        var uuid

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowerAssetDownload-\(uuid().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try await cloudAssetClient.download(manifest.recordName, scratch)
        let data = try Data(contentsOf: scratch, options: .mappedIfSafe)
        guard ArticleCapturePackage.sha256(data) == manifest.sha256 else {
            throw CloudAssetServiceError.integrityFailure
        }

        // Reuse the exact hydration path the legacy sync-table zips take:
        // sha-verify, unpack to staging, atomic install, local row update.
        try await WebsiteImportService.hydrateWebsite(
            itemID: manifest.itemID,
            archive: WebsiteArchiveBytes(
                zipData: data,
                originalFilename: manifest.originalFilename,
                sha256: manifest.sha256
            ),
            repository: repository
        )
    }

    /// Rebuilds the reader's per-page JPEGs from freshly downloaded PDF
    /// bytes. The reader document (block structure, text) was never deleted —
    /// its figure blocks reference `pdf-page-N.jpg` by position, so pages
    /// rasterized from the identical PDF line up exactly.
    static func rerasterizePages(itemID: UUID, pdfURL: URL) throws {
        guard let pdf = PDFDocument(url: pdfURL) else {
            throw CloudAssetServiceError.unreadablePDF
        }
        PDFArchiver.deletePageImages(for: itemID)
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex),
                  let image = rasterizePage(page, scale: 2.0)
            else { continue }
            try PDFArchiver.archivePageImage(image, for: itemID, pageIndex: pageIndex)
        }
    }

    private static func restoreFailureMessage(_ error: Error) -> String {
        switch error {
        case CloudAssetError.notAuthenticated:
            return "Sign in to iCloud to download this item."
        case CloudAssetError.transient, CloudAssetServiceError.integrityFailure:
            return "This item is stored in iCloud. Connect to the internet and try again."
        case CloudAssetError.assetMissing, CloudAssetServiceError.missingManifest:
            return "This item's iCloud copy could not be found. Re-import it to restore it."
        default:
            return error.localizedDescription
        }
    }

    // MARK: Backfill

    /// The date existing website zips start migrating out of the SyncEngine
    /// table. Gives older app versions a window to update before re-hydration
    /// stops working for migrated items. PDF uploads are net-new (nothing is
    /// deleted) and are not gated.
    ///
    /// Set roughly two weeks after the release that ships this feature.
    static let websiteMigrationEligibleAfter = Date(timeIntervalSince1970: 1_790_812_800)  // 2026-10-01T00:00:00Z

    /// Enqueues upload jobs for PDFs that have never been uploaded and, once
    /// the gate date passes, migration jobs for legacy website zips.
    /// Returns the number of jobs enqueued.
    @discardableResult
    public static func enqueueBackfillJobs(repository: StowerRepository) async throws -> Int {
        @Dependency(\.itemStorageClient)
        var itemStorageClient
        @Dependency(\.date.now)
        var now

        var enqueued = 0
        for itemID in try await itemStorageClient.pdfItemIDsWithoutManifest() {
            guard PDFArchiver.pdfExists(for: itemID) else { continue }
            let payload = try AssetJobPayload(itemID: itemID, kind: .pdf).encoded()
            try await repository.enqueueIngestionJob(.uploadAsset, payload)
            enqueued += 1
        }
        if now >= websiteMigrationEligibleAfter {
            for itemID in try await itemStorageClient.websiteZipItemIDsWithoutManifest() {
                let payload = try AssetJobPayload(itemID: itemID, kind: .websiteZip).encoded()
                try await repository.enqueueIngestionJob(.migrateWebsiteAsset, payload)
                enqueued += 1
            }
        }
        return enqueued
    }
}
