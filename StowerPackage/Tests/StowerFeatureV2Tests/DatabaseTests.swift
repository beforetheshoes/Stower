import Dependencies
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct DatabaseTests {
    @Test
    func articleCaptureManifestChunksAndPartialStateRoundTrip() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        var ingestion = IngestionResult.sharedText("Meaningful partial article content")
        ingestion.processingState = .partial
        ingestion.processingError = "One image was unavailable."
        let item = try await repository.createItemFromIngestion(ingestion)
        #expect(item.processingState == .partial)

        let captureID = UUID()
        let bytes = Data("capture bytes".utf8)
        let chunk = WebCaptureChunk(sequence: 0, data: bytes, sha256: ArticleCapturePackage.sha256(bytes))
        let manifest = WebCaptureManifest(
            itemID: item.id,
            captureID: captureID,
            sha256: ArticleCapturePackage.sha256(bytes),
            byteCount: bytes.count,
            chunkCount: 1
        )
        try await repository.saveArticleCapture(manifest, [chunk])
        let loaded = try #require(try await repository.loadArticleCapture(item.id))
        #expect(loaded.manifest.itemID == manifest.itemID)
        #expect(loaded.manifest.captureID == manifest.captureID)
        #expect(loaded.manifest.sha256 == manifest.sha256)
        #expect(loaded.manifest.byteCount == manifest.byteCount)
        #expect(abs(loaded.manifest.capturedAt.timeIntervalSince(manifest.capturedAt)) < 0.01)
        #expect(loaded.chunks == [chunk])

        try await repository.markArticleCaptureInstalled(item.id, captureID, 1)
        #expect(try await repository.loadItem(item.id)?.captureVersion == 1)
    }

    @Test
    func bootstrapAndCRUD() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        let ingestion = IngestionResult.sharedText("A body of content")
        let saved = try await repository.createItemFromIngestion(ingestion)
        let items = try await repository.fetchLibrary(.all)

        #expect(items.count >= 1)
        #expect(items.contains { $0.id == saved.id })
    }

    @Test
    func documentRoundTrip() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        let result = IngestionResult.sharedText("Document text")
        let item = try await repository.createItemFromIngestion(result)

        let loaded = try await repository.loadReaderDocument(item.id)
        let unwrapped = try #require(loaded)
        #expect(unwrapped.blocks.count == 1)
    }

    @Test
    func summaryCacheSeparatesQualityVersionAndArticleContent() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let item = try await repository.createItemFromIngestion(.sharedText("Original article"))

        try await repository.saveSummary(item.id, "quick", 2, "Quick result")
        try await repository.saveSummary(item.id, "enhanced", 1, "Enhanced result")

        #expect(try await repository.loadSummary(item.id, "quick", 2)?.text == "Quick result")
        #expect(try await repository.loadSummary(item.id, "enhanced", 1)?.text == "Enhanced result")
        #expect(try await repository.loadSummary(item.id, "quick", 3) == nil)

        let replacement = ReaderDocument(
            title: "Updated",
            blocks: [.paragraph([.text("Updated article")])],
            sourceURL: nil
        )
        try await repository.saveReaderDocument(item.id, replacement, "Updated article")

        #expect(try await repository.loadSummary(item.id, "quick", 2) == nil)
        #expect(try await repository.loadSummary(item.id, "enhanced", 1) == nil)
    }

    @Test
    func editableTextSource_roundTripsRawSourceAndMode() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        let created = try await repository.createItemFromIngestion(
            .sharedText(
                "Line one\nLine two",
                explicitTitle: "Manual Title",
                rawSourceText: "Line one\nLine two",
                rawSourceMode: .plainText
            )
        )

        let editable = try await repository.loadEditableTextSource(created.id)
        let unwrapped = try #require(editable)
        #expect(unwrapped.title == "Manual Title")
        #expect(unwrapped.text == "Line one\nLine two")
        // The editor always loads .auto so the preview can auto-detect
        // markdown vs plain text, regardless of the stored mode.
        #expect(unwrapped.mode == .auto)
    }

    @Test
    func ingestionQueueRoundTrip() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        try await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 1000)
            $0.uuid = .constant(UUID(0))
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        }
        let first = try #require(
            try await repository.claimNextIngestionJob(Date(timeIntervalSince1970: 1000))
        )
        #expect(first.payload == "https://example.com/post")
        try await repository.completeIngestionJob(first.id, Date(timeIntervalSince1970: 1001))
        #expect(try await repository.claimNextIngestionJob(Date(timeIntervalSince1970: 1002)) == nil)
    }

    @Test
    func ingestionClaimsAreAtomicAndStaleClaimsRecover() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let start = Date(timeIntervalSince1970: 2000)

        try await withDependencies {
            $0.date.now = start
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.text, "recover me")
        }

        let firstClaim = try #require(try await repository.claimNextIngestionJob(start))
        #expect(firstClaim.attemptCount == 1)
        #expect(try await repository.claimNextIngestionJob(start) == nil)

        let recovered = try #require(
            try await repository.claimNextIngestionJob(start.addingTimeInterval(601))
        )
        #expect(recovered.id == firstClaim.id)
        #expect(recovered.attemptCount == 2)
    }

    @Test
    func poisonImportFailsAfterThreeAttemptsWithoutBlockingLaterJobs() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 3000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.text, "poison")
            try await repository.enqueueIngestionJob(.text, "healthy")
        }

        for attempt in 1...3 {
            let job = try #require(try await repository.claimNextIngestionJob(now))
            #expect(job.payload == "poison")
            #expect(job.attemptCount == attempt)
            try await repository.failIngestionJob(job.id, "Malformed import", now)
        }

        let next = try #require(try await repository.claimNextIngestionJob(now))
        #expect(next.payload == "healthy")
        let failures = try await repository.fetchFailedIngestionJobs()
        #expect(failures.count == 1)
        #expect(failures.first?.lastError == "Malformed import")

        try await repository.retryFailedIngestionJobs()
        #expect(try await repository.fetchFailedIngestionJobs().isEmpty)
    }

    @Test
    func createThenLoadItem_sameAsReaderFlow() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        // Simulate what saveURLTapped does
        let ingestion = IngestionResult.sharedText("Test content for reader")
        let created = try await repository.createItemFromIngestion(ingestion)

        // Simulate what fetchLibrary does (user sees item in list)
        let library = try await repository.fetchLibrary(.all)
        let libraryItem = try #require(library.first { $0.id == created.id })

        // Simulate what ReaderFeature.load does (user taps item)
        let loadedItem = try await repository.loadItem(libraryItem.id)
        let loadedDoc = try await repository.loadReaderDocument(libraryItem.id)
        _ = try await repository.loadSourceHTML(libraryItem.id)

        #expect(loadedItem != nil, "loadItem returned nil — this causes 'Item not found'")
        #expect(loadedItem?.id == created.id)
        #expect(loadedDoc != nil, "loadReaderDocument returned nil")
        #expect(loadedDoc?.blocks.count == 1)
        // sourceHTML may be empty for sharedText ingestion, that's OK
    }

    @Test
    func readerAppearance_roundTrip_defaultsAndUpdate() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        let defaults = try await repository.loadReaderAppearanceSettings()
        #expect(defaults == ReaderAppearanceSettings())

        let updated = ReaderAppearanceSettings(
            fontSize: 24,
            fontStyle: .avenirNext,
            lineSpacing: 12,
            justification: .justified,
            background: .sepia,
            primaryAccent: .cyan,
            secondaryAccent: .magenta,
            lineWidth: 760
        )
        try await repository.saveReaderAppearanceSettings(updated)

        let reloaded = try await repository.loadReaderAppearanceSettings()
        #expect(reloaded == updated)

        let secondRepository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let persisted = try await secondRepository.loadReaderAppearanceSettings()
        #expect(persisted == updated)
    }
}
