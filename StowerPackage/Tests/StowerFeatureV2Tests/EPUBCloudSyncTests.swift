import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing

/// Books sync as their original file: the importing device uploads the EPUB
/// to the asset store, and every other device downloads and imports it.
/// `.serialized` because both "devices" share this machine's archive
/// directory, keyed by the same item ID.
@Suite(.serialized)
struct EPUBCloudSyncTests {
    struct Device {
        var database: any DatabaseWriter
        var repository: StowerRepository
        var itemStorage: ItemStorageClient

        init() throws {
            database = try StowerDatabase.makeDatabase()
            repository = .live(database: database, cloudSyncClient: .noop)
            itemStorage = .live(database: database)
        }
    }

    private func onDevice<T>(
        _ device: Device,
        store: InMemoryCloudAssetStore,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await withDependencies {
            $0.cloudAssetClient = store.client
            $0.itemStorageClient = device.itemStorage
            $0.cloudSyncClient = .noop
            $0.stowerRepository = device.repository
            $0.epubIngestionClient = .live
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
            $0.uuid = UUIDGenerator { UUID() }
        } operation: {
            try await operation()
        }
    }

    /// Imports the fixture book on `device` and uploads it, the way the
    /// library import path does.
    private func importAndUpload(
        on device: Device,
        store: InMemoryCloudAssetStore
    ) async throws -> (item: SavedItem, manifest: AssetManifest) {
        let url = try EPUBFixture.write(EPUBFixture.bookEntries(), filename: "The Test Book.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        return try await onDevice(device, store: store) {
            let result = try await EPUBIngestor.ingest(url: url)
            let item = try await device.repository.createItemFromIngestion(result)
            try EPUBBookArchiver.archiveBook(from: url, itemID: item.id)
            try await CloudAssetService.upload(
                payload: AssetJobPayload(itemID: item.id, kind: .epub, originalFilename: url.lastPathComponent)
            )
            let manifest = try await device.itemStorage.manifest(item.id, .epub)
            return (item, try #require(manifest))
        }
    }

    /// Writes the rows CloudKit sync would deliver to a second device: the
    /// item and its asset manifest, with no local content.
    private func deliverSyncedRows(
        to device: Device,
        item: SavedItem,
        manifest: AssetManifest
    ) async throws {
        try await device.database.write { db in
            try SavedItemSyncTable
                .insert {
                    SavedItemSyncTable.Draft(id: item.id, title: item.title, canonicalURL: item.canonicalURL)
                }
                .execute(db)
        }
        try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        } operation: {
            try await device.itemStorage.upsertManifest(manifest)
        }
    }

    @Test
    func importedBookUploadsItsOriginalFile() async throws {
        let store = InMemoryCloudAssetStore()
        let device = try Device()
        let (item, manifest) = try await importAndUpload(on: device, store: store)
        defer { AssetArchiver.deleteArchive(for: item.id) }

        #expect(manifest.kind == .epub)
        #expect(manifest.originalFilename == "The Test Book.epub")
        let bookData = try Data(contentsOf: EPUBBookArchiver.bookURL(for: item.id))
        #expect(manifest.sha256 == ArticleCapturePackage.sha256(bookData))
        #expect(await store.records[manifest.recordName] == bookData)
        // The book's text does not also travel through the text sync table.
        let textRows = try await device.database.read { db in
            try SavedTextContentSyncTable.fetchCount(db)
        }
        #expect(textRows == 0)
    }

    @Test
    func secondDeviceDownloadsAndImportsTheBook() async throws {
        let store = InMemoryCloudAssetStore()
        let first = try Device()
        let (item, manifest) = try await importAndUpload(on: first, store: store)
        defer { AssetArchiver.deleteArchive(for: item.id) }
        let firstDocument = try await first.repository.loadReaderDocument(item.id)

        // The second device starts with nothing on disk.
        AssetArchiver.deleteArchive(for: item.id)
        let second = try Device()
        try await deliverSyncedRows(to: second, item: item, manifest: manifest)

        try await onDevice(second, store: store) {
            #expect(try await second.repository.hydrateBookItemsFromSyncedContent() == 1)
            // A second pass while the download is still queued adds nothing.
            #expect(try await second.repository.hydrateBookItemsFromSyncedContent() == 0)

            let claimed = try await second.repository.claimNextIngestionJob(
                Date(timeIntervalSince1970: 1_700_000_000)
            )
            let job = try #require(claimed)
            #expect(job.kind == .downloadAsset)
            let payload = try AssetJobPayload.decoded(from: job.payload)
            #expect(payload.itemID == item.id)
            try await CloudAssetService.restore(itemID: payload.itemID, repository: second.repository)
            try await second.repository.completeIngestionJob(job.id, Date(timeIntervalSince1970: 1_700_000_000))

            // Once the book is readable there is nothing left to fetch.
            #expect(try await second.repository.hydrateBookItemsFromSyncedContent() == 0)
        }

        let secondDocument = try await second.repository.loadReaderDocument(item.id)
        #expect(secondDocument?.blocks == firstDocument?.blocks)
        #expect(secondDocument?.blocks.isEmpty == false)
        #expect(
            EPUBBookArchiver.imageURLs(for: item.id).map(\.lastPathComponent).sorted()
                == ["epub-img-0.png", "epub-img-cover.jpg"]
        )
        #expect(FileManager.default.fileExists(atPath: EPUBBookArchiver.bookURL(for: item.id).path))
        let status = try await second.database.read { db in
            try SavedItemContentLocalTable.find(item.id).fetchOne(db)?.localStatus
        }
        #expect(status == "available")
    }

    @Test
    func corruptedDownloadIsRejected() async throws {
        let store = InMemoryCloudAssetStore()
        let first = try Device()
        let (item, manifest) = try await importAndUpload(on: first, store: store)
        defer { AssetArchiver.deleteArchive(for: item.id) }

        AssetArchiver.deleteArchive(for: item.id)
        let second = try Device()
        try await deliverSyncedRows(to: second, item: item, manifest: manifest)
        await store.setFailures([.truncateDownloads])

        try await onDevice(second, store: store) {
            _ = try await second.repository.hydrateBookItemsFromSyncedContent()
            await #expect(throws: CloudAssetServiceError.integrityFailure) {
                try await CloudAssetService.restore(itemID: item.id, repository: second.repository)
            }
        }
        #expect(EPUBBookArchiver.imageURLs(for: item.id).isEmpty)
        let status = try await second.database.read { db in
            try SavedItemContentLocalTable.find(item.id).fetchOne(db)?.localStatus
        }
        #expect(status == "failed")
    }

    @Test
    func downloadThatRanOutOfAttemptsIsRetriedOnTheNextPass() async throws {
        let store = InMemoryCloudAssetStore()
        let first = try Device()
        let (item, manifest) = try await importAndUpload(on: first, store: store)
        defer { AssetArchiver.deleteArchive(for: item.id) }

        let second = try Device()
        try await deliverSyncedRows(to: second, item: item, manifest: manifest)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await onDevice(second, store: store) {
            #expect(try await second.repository.hydrateBookItemsFromSyncedContent() == 1)
            // Three failed attempts park the job as failed.
            for _ in 0..<3 {
                let claimed = try await second.repository.claimNextIngestionJob(now)
                let job = try #require(claimed)
                try await second.repository.failIngestionJob(job.id, "offline", now)
            }
            #expect(try await second.repository.claimNextIngestionJob(now) == nil)

            #expect(try await second.repository.hydrateBookItemsFromSyncedContent() == 1)
            let retried = try await second.repository.claimNextIngestionJob(now)
            #expect(retried?.kind == .downloadAsset)
        }
        let jobCount = try await second.database.read { db in
            try IngestionJobLocalTable.fetchCount(db)
        }
        #expect(jobCount == 1)
    }

    @Test
    func deletedBooksAreNotDownloaded() async throws {
        let store = InMemoryCloudAssetStore()
        let first = try Device()
        let (item, manifest) = try await importAndUpload(on: first, store: store)
        defer { AssetArchiver.deleteArchive(for: item.id) }

        let second = try Device()
        try await deliverSyncedRows(to: second, item: item, manifest: manifest)
        try await second.database.write { db in
            try SavedItemSyncTable
                .find(item.id)
                .update { $0.deletedAt = #bind(Date(timeIntervalSince1970: 1_700_000_000)) }
                .execute(db)
        }

        let enqueued = try await onDevice(second, store: store) {
            try await second.repository.hydrateBookItemsFromSyncedContent()
        }
        #expect(enqueued == 0)
    }

    @Test
    func backfillRetriesBooksThatNeverUploaded() async throws {
        let store = InMemoryCloudAssetStore()
        let device = try Device()
        let url = try EPUBFixture.write(EPUBFixture.bookEntries())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await onDevice(device, store: store) {
            let result = try await EPUBIngestor.ingest(url: url)
            let item = try await device.repository.createItemFromIngestion(result)
            defer { AssetArchiver.deleteArchive(for: item.id) }
            try EPUBBookArchiver.archiveBook(from: url, itemID: item.id)

            _ = try await CloudAssetService.enqueueBackfillJobs(repository: device.repository)

            let jobs = try await device.database.read { db in
                try IngestionJobLocalTable
                    .where { $0.kind.eq(IngestionJob.Kind.uploadAsset.rawValue) }
                    .fetchAll(db)
            }
            let payloads = try jobs.map { try AssetJobPayload.decoded(from: $0.payload) }
            #expect(payloads.contains { $0.itemID == item.id && $0.kind == .epub })
        }
    }
}
