import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing

/// Phase 3: web article capture packages live in the CloudKit asset store.
/// Capture manifests with `chunkCount == 0` mark asset-store captures; chunk
/// rows are the legacy representation and get migrated upload-first.
@Suite
struct CaptureAssetStoreTests {
    struct Fixture {
        var database: any DatabaseWriter
        var repository: StowerRepository
        var itemStorage: ItemStorageClient
        var store: InMemoryCloudAssetStore
        var uuid = UUIDGenerator { UUID() }
    }

    private func makeFixture() throws -> Fixture {
        let database = try StowerDatabase.makeDatabase()
        return Fixture(
            database: database,
            repository: .live(database: database, cloudSyncClient: .noop),
            itemStorage: .live(database: database),
            store: InMemoryCloudAssetStore()
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
            $0.uuid = fixture.uuid
        } operation: {
            try await operation()
        }
    }

    /// Seeds a legacy chunked capture the way pre-Phase-3 builds wrote them.
    private func seedChunkedCapture(
        _ fixture: Fixture,
        itemID: UUID,
        package: Data
    ) async throws -> WebCaptureManifest {
        let chunkSize = 8
        let chunks = stride(from: 0, to: package.count, by: chunkSize).enumerated().map { sequence, offset in
            let data = package.subdata(in: offset..<min(offset + chunkSize, package.count))
            return WebCaptureChunk(sequence: sequence, data: data, sha256: ArticleCapturePackage.sha256(data))
        }
        let manifest = WebCaptureManifest(
            itemID: itemID,
            captureID: UUID(),
            sha256: ArticleCapturePackage.sha256(package),
            byteCount: package.count,
            chunkCount: chunks.count
        )
        try await fixture.repository.saveArticleCapture(manifest, chunks)
        return manifest
    }

    @Test
    func saveArticleCapture_acceptsChunklessAssetStoreManifest() async throws {
        let fixture = try makeFixture()
        let item = try await withFixtureDependencies(fixture) {
            try await fixture.repository.createItemFromIngestion(.sharedText("Article"))
        }
        let package = Data("capture package bytes".utf8)
        let manifest = WebCaptureManifest(
            itemID: item.id,
            captureID: UUID(),
            sha256: ArticleCapturePackage.sha256(package),
            byteCount: package.count,
            chunkCount: 0
        )

        try await withFixtureDependencies(fixture) {
            try await fixture.repository.saveArticleCapture(manifest, [])
        }

        let synced = try await fixture.repository.loadArticleCapture(item.id)
        #expect(synced?.manifest.chunkCount == 0)
        #expect(synced?.manifest.byteCount == package.count)
        #expect(synced?.chunks.isEmpty == true)
        // A mismatched chunk set is still rejected.
        await #expect(throws: ArticleCaptureRepositoryError.incompleteChunkSet) {
            let bad = WebCaptureManifest(
                itemID: item.id,
                captureID: UUID(),
                sha256: "x",
                byteCount: 10,
                chunkCount: 2
            )
            try await fixture.repository.saveArticleCapture(bad, [])
        }
    }

    @Test
    func hydrate_downloadsChunklessCaptureFromAssetStore() async throws {
        let fixture = try makeFixture()
        let item = try await withFixtureDependencies(fixture) {
            try await fixture.repository.createItemFromIngestion(.sharedText("Article"))
        }
        defer { AssetArchiver.deleteArchive(for: item.id) }

        // Build a real capture package zip so install() accepts it.
        let captureID = UUID()
        let artifact = try ArticleCapturePackage.stage(
            captureID: captureID,
            sourceURL: URL(string: "https://example.com/story")!,
            content: ArticleCapturePackage.Content(
                readerArchive: Data("reader".utf8),
                originalArchive: Data("original".utf8),
                document: ReaderDocument(title: "Story", blocks: [.paragraph([.text("Body")])]),
                plainText: "Body"
            ),
            completeness: .complete,
            warnings: []
        )
        defer { try? FileManager.default.removeItem(at: artifact.stagedPackageURL.deletingLastPathComponent()) }
        let package = try Data(contentsOf: artifact.stagedPackageURL)

        // Chunkless manifest synced; bytes only in the asset store.
        let manifest = WebCaptureManifest(
            itemID: item.id,
            captureID: captureID,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount,
            chunkCount: 0
        )
        try await withFixtureDependencies(fixture) {
            try await fixture.repository.saveArticleCapture(manifest, [])
        }
        let recordName = AssetManifest.makeRecordName(
            kind: .capture,
            itemID: item.id,
            sha256: artifact.sha256
        )
        try await fixture.store.put(recordName, data: package)

        let result = try await withFixtureDependencies(fixture) {
            try await ArticleSaveClient.live.hydrate(
                item.id,
                URL(string: "https://example.com/story")!
            )
        }

        #expect(result.state == .ready)
        #expect(ArticleCapturePackage.archiveURL(for: item.id, original: true) != nil)
        #expect(ArticleCapturePackage.archiveURL(for: item.id, original: false) != nil)
    }

    @Test
    func hydrate_throwsWhenAssetUnavailableInsteadOfRefetching() async throws {
        let fixture = try makeFixture()
        let item = try await withFixtureDependencies(fixture) {
            try await fixture.repository.createItemFromIngestion(.sharedText("Article"))
        }
        let manifest = WebCaptureManifest(
            itemID: item.id,
            captureID: UUID(),
            sha256: "deadbeef",
            byteCount: 42,
            chunkCount: 0
        )
        try await withFixtureDependencies(fixture) {
            try await fixture.repository.saveArticleCapture(manifest, [])
        }

        // Empty asset store: hydration must fail loudly, not fall back to a
        // live refetch that would replace the exact capture.
        await #expect(throws: (any Error).self) {
            try await withFixtureDependencies(fixture) {
                _ = try await ArticleSaveClient.live.hydrate(
                    item.id,
                    URL(string: "https://example.com/story")!
                )
            }
        }
    }

    @Test
    func migrateCapture_uploadsThenDeletesChunks() async throws {
        let fixture = try makeFixture()
        let item = try await withFixtureDependencies(fixture) {
            try await fixture.repository.createItemFromIngestion(.sharedText("Chunked"))
        }
        let package = Data("legacy chunked capture package".utf8)
        let manifest = try await withFixtureDependencies(fixture) {
            try await seedChunkedCapture(fixture, itemID: item.id, package: package)
        }

        try await withFixtureDependencies(fixture) {
            try await CloudAssetService.migrateCapture(itemID: item.id, repository: fixture.repository)
        }

        // Asset holds the exact package, chunk rows are gone, and the synced
        // capture manifest now says chunkCount == 0.
        let recordName = AssetManifest.makeRecordName(
            kind: .capture,
            itemID: item.id,
            sha256: manifest.sha256
        )
        let cloudCopy = try await fixture.store.get(recordName)
        #expect(cloudCopy == package)
        let synced = try await fixture.repository.loadArticleCapture(item.id)
        #expect(synced?.manifest.chunkCount == 0)
        #expect(synced?.chunks.isEmpty == true)
        let chunkRows = try await fixture.database.read { db in
            try SavedArticleCaptureChunkSyncTable.where { $0.itemID.eq(item.id) }.fetchCount(db)
        }
        #expect(chunkRows == 0)
        let info = try await fixture.itemStorage.storageInfo(item.id)
        #expect(info?.uploadState == "uploaded")
        #expect(info?.assetManifests.contains { $0.kind == .capture } == true)
    }

    @Test
    func migrateCapture_keepsChunksWhenUploadCannotBeVerified() async throws {
        let fixture = try makeFixture()
        await fixture.store.setFailures([.existsAlwaysFalse])
        let item = try await withFixtureDependencies(fixture) {
            try await fixture.repository.createItemFromIngestion(.sharedText("Chunked"))
        }
        let package = Data("only copy of this capture".utf8)
        _ = try await withFixtureDependencies(fixture) {
            try await seedChunkedCapture(fixture, itemID: item.id, package: package)
        }

        await #expect(throws: (any Error).self) {
            try await withFixtureDependencies(fixture) {
                try await CloudAssetService.migrateCapture(itemID: item.id, repository: fixture.repository)
            }
        }

        // Upload-verify-then-delete invariant: chunks must survive.
        let synced = try await fixture.repository.loadArticleCapture(item.id)
        #expect(synced?.manifest.chunkCount ?? 0 > 0)
        let reconstructed = try ArticleCapturePackage.reconstruct(try #require(synced))
        #expect(reconstructed == package)
    }

    @Test
    func backfill_retriesUploadsWithStagedPayloadsOnDisk() async throws {
        let fixture = try makeFixture()
        let (captureItem, websiteItem) = try await withFixtureDependencies(fixture) {
            (
                try await fixture.repository.createItemFromIngestion(.sharedText("Capture")),
                try await fixture.repository.createItemFromIngestion(.sharedText("Website"))
            )
        }
        defer {
            AssetArchiver.deleteArchive(for: captureItem.id)
            AssetArchiver.deleteArchive(for: websiteItem.id)
        }
        // A first upload attempt failed (e.g. CloudKit schema not deployed),
        // leaving the staged payloads on disk.
        let pendingCapture = CloudAssetService.pendingUploadCaptureURL(for: captureItem.id)
        try FileManager.default.createDirectory(
            at: pendingCapture.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("capture".utf8).write(to: pendingCapture)
        let pendingZip = CloudAssetService.pendingUploadZipURL(for: websiteItem.id)
        try FileManager.default.createDirectory(
            at: pendingZip.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("zip".utf8).write(to: pendingZip)

        let enqueued = try await withFixtureDependencies(fixture) {
            try await CloudAssetService.enqueueBackfillJobs(repository: fixture.repository)
        }

        #expect(enqueued >= 2)
        let uploadJobs = try await fixture.database.read { db in
            try IngestionJobLocalTable
                .where { $0.kind.eq(IngestionJob.Kind.uploadAsset.rawValue) }
                .select(\.payload)
                .fetchAll(db)
        }
        let payloads = try uploadJobs.map { try AssetJobPayload.decoded(from: $0) }
        #expect(payloads.contains { $0.itemID == captureItem.id && $0.kind == .capture })
        #expect(payloads.contains { $0.itemID == websiteItem.id && $0.kind == .websiteZip })
    }

    @Test
    func uploadCapture_fallsBackToChunkRowsWhenPendingZipMissing() async throws {
        let fixture = try makeFixture()
        let item = try await withFixtureDependencies(fixture) {
            try await fixture.repository.createItemFromIngestion(.sharedText("Chunked"))
        }
        let package = Data("chunked but never staged".utf8)
        let manifest = try await withFixtureDependencies(fixture) {
            try await seedChunkedCapture(fixture, itemID: item.id, package: package)
        }

        try await withFixtureDependencies(fixture) {
            try await CloudAssetService.upload(
                payload: AssetJobPayload(itemID: item.id, kind: .capture)
            )
        }

        let recordName = AssetManifest.makeRecordName(
            kind: .capture,
            itemID: item.id,
            sha256: manifest.sha256
        )
        let cloudCopy = try await fixture.store.get(recordName)
        #expect(cloudCopy == package)
        // Upload alone does NOT delete the chunk rows — that is the
        // migration job's explicit responsibility.
        let synced = try await fixture.repository.loadArticleCapture(item.id)
        #expect(synced?.manifest.chunkCount ?? 0 > 0)
    }
}
