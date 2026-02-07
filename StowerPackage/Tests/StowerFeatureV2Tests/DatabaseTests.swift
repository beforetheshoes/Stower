import Foundation
import Testing
@testable import StowerFeature

@Suite
struct DatabaseTests {
    @Test
    func bootstrapAndCRUD() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database)

        let ingestion = IngestionResult.sharedText("A body of content")
        let saved = try await repository.createItemFromIngestion(ingestion)
        let items = try await repository.fetchLibrary()

        #expect(items.count >= 1)
        #expect(items.contains(where: { $0.id == saved.id }))
    }

    @Test
    func documentRoundTrip() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database)

        let result = IngestionResult.sharedText("Document text")
        let item = try await repository.createItemFromIngestion(result)

        let loaded = try await repository.loadReaderDocument(item.id)
        let unwrapped = try #require(loaded)
        #expect(unwrapped.blocks.count == 1)
    }

    @Test
    func ingestionQueueRoundTrip() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database)

        try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        let jobs = try await repository.fetchPendingIngestionJobs()

        #expect(!jobs.isEmpty)
        let first = try #require(jobs.first)
        try await repository.markIngestionJobProcessed(first.id)

        let remaining = try await repository.fetchPendingIngestionJobs()
        #expect(!remaining.contains(where: { $0.id == first.id }))
    }
}
