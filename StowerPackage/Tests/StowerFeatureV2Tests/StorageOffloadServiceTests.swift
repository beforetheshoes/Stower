import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct StorageOffloadServiceTests {
    // MARK: Eligibility (pure)

    private func makeInfo(
        renderFormat: String,
        isRead: Bool = true,
        isPinned: Bool = false,
        uploadState: String = "uploaded",
        offloadedAt: Date? = nil,
        hasCaptureManifest: Bool = false,
        manifestKinds: [CloudAssetKind] = []
    ) -> ItemStorageInfo {
        let itemID = UUID()
        return ItemStorageInfo(
            itemID: itemID,
            renderFormat: renderFormat,
            isRead: isRead,
            isPinned: isPinned,
            uploadState: uploadState,
            offloadedAt: offloadedAt,
            hasCaptureManifest: hasCaptureManifest,
            assetManifests: manifestKinds.map {
                AssetManifest(
                    id: UUID(),
                    itemID: itemID,
                    kind: $0,
                    recordName: "record",
                    sha256: "abc",
                    byteCount: 1,
                    originalFilename: "f"
                )
            }
        )
    }

    @Test
    func canOffload_requiresConfirmedRemoteCopy() {
        // PDFs need an uploaded manifest.
        #expect(StorageOffloadService.canOffload(makeInfo(renderFormat: "pdf", manifestKinds: [.pdf])))
        #expect(!StorageOffloadService.canOffload(
            makeInfo(renderFormat: "pdf", uploadState: "pending", manifestKinds: [.pdf])
        ))
        #expect(!StorageOffloadService.canOffload(makeInfo(renderFormat: "pdf")))

        // Website imports need an uploaded zip manifest.
        #expect(StorageOffloadService.canOffload(
            makeInfo(renderFormat: "webView", manifestKinds: [.websiteZip])
        ))
        // Interactive captures restore from local chunks — no manifest needed.
        #expect(StorageOffloadService.canOffload(
            makeInfo(renderFormat: "webView", uploadState: "pending", hasCaptureManifest: true)
        ))
        // Legacy website imports with neither are NOT offloadable yet.
        #expect(!StorageOffloadService.canOffload(
            makeInfo(renderFormat: "webView", uploadState: "pending")
        ))

        // Regular articles never offload.
        #expect(!StorageOffloadService.canOffload(
            makeInfo(renderFormat: "structuredV1", manifestKinds: [.pdf])
        ))
        // Already offloaded items are done.
        #expect(!StorageOffloadService.canOffload(
            makeInfo(renderFormat: "pdf", offloadedAt: .now, manifestKinds: [.pdf])
        ))
    }

    @Test
    func isAutoEvictable_requiresReadAndUnpinned() {
        #expect(StorageOffloadService.isAutoEvictable(makeInfo(renderFormat: "pdf", manifestKinds: [.pdf])))
        #expect(!StorageOffloadService.isAutoEvictable(
            makeInfo(renderFormat: "pdf", isRead: false, manifestKinds: [.pdf])
        ))
        #expect(!StorageOffloadService.isAutoEvictable(
            makeInfo(renderFormat: "pdf", isPinned: true, manifestKinds: [.pdf])
        ))
    }

    // MARK: Offload + eviction against a live database

    struct Fixture {
        var database: any DatabaseWriter
        var repository: StowerRepository
        var itemStorage: ItemStorageClient
        var store: InMemoryCloudAssetStore
        // Shared across every dependency scope in a test so UUIDs never
        // collide between successive fixture operations.
        var uuid: UUIDGenerator = .incrementing
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
            $0.itemStorageClient = fixture.itemStorage
            $0.cloudAssetClient = fixture.store.client
            $0.cloudSyncClient = .noop
            $0.stowerRepository = fixture.repository
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
            $0.uuid = fixture.uuid
        } operation: {
            try await operation()
        }
    }

    /// Creates a read PDF item with an on-disk archive, an uploaded manifest,
    /// and a local content row marked `pdf`.
    private func makeUploadedPDFItem(
        _ fixture: Fixture,
        pinned: Bool = false
    ) async throws -> SavedItem {
        try await withFixtureDependencies(fixture) {
            let item = try await fixture.repository.createItemFromIngestion(.sharedText("PDF"))
            try await fixture.repository.setReadStatus(item.id, true)
            try await fixture.database.write { db in
                try SavedItemContentLocalTable
                    .find(item.id)
                    .update { $0.renderFormat = "pdf" }
                    .execute(db)
            }
            let bytes = Data("pdf-bytes-\(item.id)".utf8)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
            try bytes.write(to: scratch)
            defer { try? FileManager.default.removeItem(at: scratch) }
            try PDFArchiver.archivePDF(from: scratch, itemID: item.id)
            try await CloudAssetService.upload(payload: AssetJobPayload(itemID: item.id, kind: .pdf))
            if pinned {
                try await fixture.itemStorage.setPinned(item.id, true)
            }
            return item
        }
    }

    @Test
    func offload_deletesFilesAndMarksState() async throws {
        let fixture = try makeFixture()
        let item = try await makeUploadedPDFItem(fixture)
        defer { AssetArchiver.deleteArchive(for: item.id) }
        #expect(PDFArchiver.pdfExists(for: item.id))

        try await withFixtureDependencies(fixture) {
            try await StorageOffloadService.offload(itemID: item.id, repository: fixture.repository)
        }

        #expect(!PDFArchiver.pdfExists(for: item.id))
        let info = try await fixture.itemStorage.storageInfo(item.id)
        #expect(info?.offloadedAt != nil)
        let reloaded = try await withFixtureDependencies(fixture) {
            try await fixture.repository.loadItem(item.id)
        }
        #expect(reloaded?.processingState == .queued)
    }

    @Test
    func offload_refusesWithoutConfirmedUpload() async throws {
        let fixture = try makeFixture()
        let item = try await withFixtureDependencies(fixture) {
            let item = try await fixture.repository.createItemFromIngestion(.sharedText("Local-only"))
            try await fixture.database.write { db in
                try SavedItemContentLocalTable
                    .find(item.id)
                    .update { $0.renderFormat = "pdf" }
                    .execute(db)
            }
            return item
        }

        await #expect(throws: StorageOffloadError.notOffloadable) {
            try await withFixtureDependencies(fixture) {
                try await StorageOffloadService.offload(itemID: item.id, repository: fixture.repository)
            }
        }
    }

    @Test
    func runEviction_skipsPinnedAndExcludedItems() async throws {
        let fixture = try makeFixture()
        let evictable = try await makeUploadedPDFItem(fixture)
        let pinned = try await makeUploadedPDFItem(fixture, pinned: true)
        let excluded = try await makeUploadedPDFItem(fixture)
        defer {
            AssetArchiver.deleteArchive(for: evictable.id)
            AssetArchiver.deleteArchive(for: pinned.id)
            AssetArchiver.deleteArchive(for: excluded.id)
        }

        let report = try await withFixtureDependencies(fixture) {
            try await StorageOffloadService.runEviction(
                repository: fixture.repository,
                excluding: [excluded.id],
                budgetOverride: 0
            )
        }

        #expect(report.evictedCount == 1)
        #expect(!PDFArchiver.pdfExists(for: evictable.id))
        #expect(PDFArchiver.pdfExists(for: pinned.id))
        #expect(PDFArchiver.pdfExists(for: excluded.id))
    }

    @Test
    func runEviction_withoutBudgetIsANoop() async throws {
        let fixture = try makeFixture()
        let item = try await makeUploadedPDFItem(fixture)
        defer { AssetArchiver.deleteArchive(for: item.id) }

        let report = try await withFixtureDependencies(fixture) {
            try await StorageOffloadService.runEviction(repository: fixture.repository)
        }

        #expect(report.evictedCount == 0)
        #expect(PDFArchiver.pdfExists(for: item.id))
    }

    @Test
    func runEviction_skipsItemsWhoseCloudRecordDisappeared() async throws {
        let fixture = try makeFixture()
        let item = try await makeUploadedPDFItem(fixture)
        defer { AssetArchiver.deleteArchive(for: item.id) }
        // Simulate the belt-and-suspenders case: state says uploaded but the
        // record is not actually in CloudKit.
        await fixture.store.setFailures([.existsAlwaysFalse])

        let report = try await withFixtureDependencies(fixture) {
            try await StorageOffloadService.runEviction(
                repository: fixture.repository,
                budgetOverride: 0
            )
        }

        #expect(report.evictedCount == 0)
        #expect(PDFArchiver.pdfExists(for: item.id))
    }
}
