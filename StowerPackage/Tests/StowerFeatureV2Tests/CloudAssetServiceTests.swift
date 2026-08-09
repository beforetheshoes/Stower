import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing
import ZIPFoundation

/// In-memory stand-in for the CloudKit asset zone. SQLiteData's
/// MockCloudDatabase covers SyncEngine traffic, not our direct CKDatabase
/// use, so the asset store gets its own double with injectable failures.
actor InMemoryCloudAssetStore {
    enum Failure {
        case uploadQuotaExceeded
        case downloadNetworkUnavailable
        case existsAlwaysFalse
        case truncateDownloads
    }

    private(set) var records = [String: Data]()
    private(set) var deletedRecordNames = [String]()
    var failures = Set<Failure>()

    func setFailures(_ failures: Set<Failure>) {
        self.failures = failures
    }

    func put(_ recordName: String, data: Data) throws {
        if failures.contains(.uploadQuotaExceeded) {
            throw CloudAssetError.quotaExceeded
        }
        records[recordName] = data
    }

    func get(_ recordName: String) throws -> Data {
        if failures.contains(.downloadNetworkUnavailable) {
            throw CloudAssetError.transient("network unavailable")
        }
        guard var data = records[recordName] else {
            throw CloudAssetError.assetMissing
        }
        if failures.contains(.truncateDownloads) {
            data = data.dropLast(1)
        }
        return data
    }

    func exists(_ recordName: String) -> Bool {
        if failures.contains(.existsAlwaysFalse) {
            return false
        }
        return records[recordName] != nil
    }

    func delete(_ recordName: String) {
        records[recordName] = nil
        deletedRecordNames.append(recordName)
    }

    nonisolated var client: CloudAssetClient {
        CloudAssetClient(
            upload: { manifest, fileURL in
                try await self.put(manifest.recordName, data: Data(contentsOf: fileURL))
            },
            download: { recordName, destination in
                let data = try await self.get(recordName)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
            },
            exists: { recordName in
                await self.exists(recordName)
            },
            delete: { recordName in
                await self.delete(recordName)
            }
        )
    }
}

@Suite
struct CloudAssetServiceTests {
    struct Fixture {
        var database: any DatabaseWriter
        var repository: StowerRepository
        var store: InMemoryCloudAssetStore
        var itemStorage: ItemStorageClient
    }

    private func makeFixture() throws -> Fixture {
        let database = try StowerDatabase.makeDatabase()
        return Fixture(
            database: database,
            repository: .live(database: database, cloudSyncClient: .noop),
            store: InMemoryCloudAssetStore(),
            itemStorage: .live(database: database)
        )
    }

    private func withFixtureDependencies<T>(
        _ fixture: Fixture,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await withDependencies {
            $0.cloudAssetClient = fixture.store.client
            $0.itemStorageClient = fixture.itemStorage
            $0.cloudSyncClient = .noop
            $0.stowerRepository = fixture.repository
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
            $0.uuid = UUIDGenerator { UUID() }
        } operation: {
            try await operation()
        }
    }

    private func makeWebsiteZip(index: String = "<html><title>Site</title></html>") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("site.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let indexData = Data(index.utf8)
        try archive.addEntry(
            with: "index.html",
            type: .file,
            uncompressedSize: Int64(indexData.count)
        ) { position, size in
            indexData.subdata(in: Int(position)..<(Int(position) + size))
        }
        return zipURL
    }

    // MARK: Upload

    @Test
    func uploadPDF_recordsManifestAndMarksUploaded() async throws {
        let fixture = try makeFixture()
        let item = try await fixture.repository.createItemFromIngestion(.sharedText("PDF host"))
        defer { AssetArchiver.deleteArchive(for: item.id) }
        let pdfBytes = Data("fake pdf bytes".utf8)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        try pdfBytes.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try PDFArchiver.archivePDF(from: scratch, itemID: item.id)

        try await withFixtureDependencies(fixture) {
            try await CloudAssetService.upload(
                payload: AssetJobPayload(itemID: item.id, kind: .pdf, originalFilename: "report.pdf")
            )
        }

        let manifest = try await fixture.itemStorage.manifest(item.id, .pdf)
        let stored = try #require(manifest)
        #expect(stored.sha256 == ArticleCapturePackage.sha256(pdfBytes))
        #expect(stored.byteCount == pdfBytes.count)
        #expect(stored.originalFilename == "report.pdf")
        let uploaded = await fixture.store.exists(stored.recordName)
        #expect(uploaded)
        let info = try await fixture.itemStorage.storageInfo(item.id)
        #expect(info?.uploadState == "uploaded")
    }

    @Test
    func uploadQuotaExceeded_marksUploadFailed() async throws {
        let fixture = try makeFixture()
        await fixture.store.setFailures([.uploadQuotaExceeded])
        let item = try await fixture.repository.createItemFromIngestion(.sharedText("Quota"))
        defer { AssetArchiver.deleteArchive(for: item.id) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        try Data("bytes".utf8).write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try PDFArchiver.archivePDF(from: scratch, itemID: item.id)

        await #expect(throws: CloudAssetError.quotaExceeded) {
            try await withFixtureDependencies(fixture) {
                try await CloudAssetService.upload(
                    payload: AssetJobPayload(itemID: item.id, kind: .pdf)
                )
            }
        }
        let info = try await fixture.itemStorage.storageInfo(item.id)
        #expect(info?.uploadState == "failed")
        let manifest = try await fixture.itemStorage.manifest(item.id, .pdf)
        #expect(manifest == nil)
    }

    // MARK: Website zip migration

    @Test
    func migrateWebsiteZip_uploadsThenReplacesRow() async throws {
        let fixture = try makeFixture()
        let item = try await fixture.repository.createItemFromIngestion(.sharedText("Site"))
        let zipData = Data("legacy zip bytes".utf8)
        try await withFixtureDependencies(fixture) {
            try await fixture.repository.saveWebsiteArchive(
                item.id, zipData, ArticleCapturePackage.sha256(zipData), "site.zip"
            )
        }

        try await withFixtureDependencies(fixture) {
            try await CloudAssetService.migrateWebsiteZip(
                itemID: item.id,
                repository: fixture.repository
            )
        }

        // Manifest recorded, legacy row gone, bytes in the asset store.
        let manifest = try #require(try await fixture.itemStorage.manifest(item.id, .websiteZip))
        #expect(manifest.sha256 == ArticleCapturePackage.sha256(zipData))
        let legacy = try await fixture.repository.loadWebsiteArchive(item.id)
        #expect(legacy == nil)
        let cloudCopy = try await fixture.store.get(manifest.recordName)
        #expect(cloudCopy == zipData)
    }

    @Test
    func migrateWebsiteZip_keepsRowWhenUploadCannotBeVerified() async throws {
        let fixture = try makeFixture()
        await fixture.store.setFailures([.existsAlwaysFalse])
        let item = try await fixture.repository.createItemFromIngestion(.sharedText("Site"))
        let zipData = Data("precious only copy".utf8)
        try await withFixtureDependencies(fixture) {
            try await fixture.repository.saveWebsiteArchive(
                item.id, zipData, ArticleCapturePackage.sha256(zipData), "site.zip"
            )
        }

        await #expect(throws: (any Error).self) {
            try await withFixtureDependencies(fixture) {
                try await CloudAssetService.migrateWebsiteZip(
                    itemID: item.id,
                    repository: fixture.repository
                )
            }
        }

        // The upload-verify-then-delete invariant: with verification failing,
        // the legacy sync row must survive untouched.
        let legacy = try await fixture.repository.loadWebsiteArchive(item.id)
        #expect(legacy?.zipData == zipData)
        let manifest = try await fixture.itemStorage.manifest(item.id, .websiteZip)
        #expect(manifest == nil)
    }

    // MARK: Restore

    @Test
    func restoreWebsiteZip_downloadsVerifiesAndUnpacks() async throws {
        let fixture = try makeFixture()
        let item = try await fixture.repository.createItemFromIngestion(.sharedText("Site"))
        defer { AssetArchiver.deleteArchive(for: item.id) }
        let zipURL = try makeWebsiteZip()
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }
        let zipData = try Data(contentsOf: zipURL)
        let sha256 = ArticleCapturePackage.sha256(zipData)
        let manifest = AssetManifest(
            id: UUID(),
            itemID: item.id,
            kind: .websiteZip,
            recordName: AssetManifest.makeRecordName(kind: .websiteZip, itemID: item.id, sha256: sha256),
            sha256: sha256,
            byteCount: zipData.count,
            originalFilename: "site.zip"
        )
        try await fixture.store.put(manifest.recordName, data: zipData)
        try await withFixtureDependencies(fixture) {
            try await fixture.itemStorage.upsertManifest(manifest)
        }

        try await withFixtureDependencies(fixture) {
            try await CloudAssetService.restore(itemID: item.id, repository: fixture.repository)
        }

        #expect(AssetArchiver.archiveExists(for: item.id))
        let restored = try await fixture.repository.loadItem(item.id)
        #expect(restored?.processingState == .ready)
        let info = try await fixture.itemStorage.storageInfo(item.id)
        #expect(info?.offloadedAt == nil)
    }

    @Test
    func restore_integrityFailureMarksFailedAndThrows() async throws {
        let fixture = try makeFixture()
        await fixture.store.setFailures([.truncateDownloads])
        let item = try await fixture.repository.createItemFromIngestion(.sharedText("Site"))
        defer { AssetArchiver.deleteArchive(for: item.id) }
        let zipData = Data("some zip".utf8)
        let sha256 = ArticleCapturePackage.sha256(zipData)
        let manifest = AssetManifest(
            id: UUID(),
            itemID: item.id,
            kind: .websiteZip,
            recordName: AssetManifest.makeRecordName(kind: .websiteZip, itemID: item.id, sha256: sha256),
            sha256: sha256,
            byteCount: zipData.count,
            originalFilename: "site.zip"
        )
        try await fixture.store.put(manifest.recordName, data: zipData)
        try await withFixtureDependencies(fixture) {
            try await fixture.itemStorage.upsertManifest(manifest)
        }

        await #expect(throws: CloudAssetServiceError.integrityFailure) {
            try await withFixtureDependencies(fixture) {
                try await CloudAssetService.restore(itemID: item.id, repository: fixture.repository)
            }
        }
        let restored = try await fixture.repository.loadItem(item.id)
        #expect(restored?.processingState == .failed)
    }

    @Test
    func restore_withoutAnySourceThrowsMissingManifest() async throws {
        let fixture = try makeFixture()
        let item = try await fixture.repository.createItemFromIngestion(.sharedText("Empty"))

        await #expect(throws: CloudAssetServiceError.missingManifest) {
            try await withFixtureDependencies(fixture) {
                try await CloudAssetService.restore(itemID: item.id, repository: fixture.repository)
            }
        }
    }
}
