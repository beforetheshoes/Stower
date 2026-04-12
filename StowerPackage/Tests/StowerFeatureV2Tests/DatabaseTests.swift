import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct DatabaseTests {
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
    func ingestionQueueRoundTrip() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        let jobs = try await repository.fetchPendingIngestionJobs()

        #expect(!jobs.isEmpty)
        let first = try #require(jobs.first)
        try await repository.markIngestionJobProcessed(first.id)

        let remaining = try await repository.fetchPendingIngestionJobs()
        #expect(!remaining.contains { $0.id == first.id })
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
        let loadedHTML = try await repository.loadSourceHTML(libraryItem.id)

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
