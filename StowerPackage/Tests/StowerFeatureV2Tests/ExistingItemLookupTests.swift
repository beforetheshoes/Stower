import Foundation
import SQLiteData
@testable import StowerData
import Testing

/// Saving a URL that is already in the library must land on the same item,
/// whichever ID that item was first given.
@Suite
struct ExistingItemLookupTests {
    private func makeDatabase() throws -> any DatabaseWriter {
        try StowerDatabase.makeDatabase()
    }

    private func insert(
        _ id: UUID,
        url: String?,
        into database: any DatabaseWriter,
        canonical: String? = nil,
        createdAt: TimeInterval = 100,
        deleted: Bool = false
    ) async throws {
        try await database.write { db in
            try SavedItemSyncTable.insert {
                SavedItemSyncTable(
                    id: id,
                    title: "Item",
                    sourceURL: url,
                    canonicalURL: canonical,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    deletedAt: deleted ? Date(timeIntervalSince1970: 500) : nil
                )
            }
            .execute(db)
        }
    }

    private func lookup(_ url: String?, in database: any DatabaseWriter) async throws -> UUID? {
        try await database.read { db in
            try StowerRepository.existingLiveItemID(db, matching: url)
        }
    }

    @Test
    func anItemSavedUnderItsDeterministicIDIsFoundDirectly() async throws {
        let database = try makeDatabase()
        let url = "https://example.com/post"
        let stableID = StowerRepository.stableItemID(from: url)
        try await insert(stableID, url: url, into: database)
        try await insert(UUID(9), url: "https://example.com/other", into: database)

        #expect(try await lookup(url, in: database) == stableID)
    }

    @Test
    func anItemSavedUnderAnotherIDIsFoundByItsNormalizedURL() async throws {
        let database = try makeDatabase()
        let legacyID = UUID(7)
        try await insert(legacyID, url: "https://EXAMPLE.com/post#section", into: database)
        try await insert(UUID(8), url: "https://example.com/unrelated", into: database)
        try await insert(UUID(9), url: "https://elsewhere.org/post", into: database)

        #expect(try await lookup("https://example.com/post", in: database) == legacyID)
    }

    @Test
    func theCanonicalURLIsWhatMatchesWhenThereIsOne() async throws {
        let database = try makeDatabase()
        let id = UUID(7)
        try await insert(id, url: "https://t.co/short", into: database, canonical: "https://example.com/post")

        #expect(try await lookup("https://example.com/post", in: database) == id)
        #expect(try await lookup("https://t.co/short", in: database) == nil)
    }

    @Test
    func theDeterministicIDWinsOverOtherMatchesAndNewestWinsOtherwise() async throws {
        let database = try makeDatabase()
        let url = "https://example.com/post"
        let older = UUID(1)
        let newer = UUID(2)
        try await insert(older, url: url, into: database, createdAt: 100)
        try await insert(newer, url: url, into: database, createdAt: 200)
        #expect(try await lookup(url, in: database) == newer)

        let stableID = StowerRepository.stableItemID(from: url)
        try await insert(stableID, url: url, into: database, createdAt: 50)
        #expect(try await lookup(url, in: database) == stableID)
    }

    @Test
    func trashedItemsAndUnknownURLsDoNotMatch() async throws {
        let database = try makeDatabase()
        let url = "https://example.com/post"
        try await insert(StowerRepository.stableItemID(from: url), url: url, into: database, deleted: true)
        try await insert(UUID(3), url: url, into: database, deleted: true)

        #expect(try await lookup(url, in: database) == nil)
        #expect(try await lookup("https://example.com/never-saved", in: database) == nil)
        #expect(try await lookup(nil, in: database) == nil)
    }

    @Test
    func hostsThatContainLikeWildcardsAreMatchedLiterally() async throws {
        let database = try makeDatabase()
        let id = UUID(4)
        try await insert(id, url: "https://my_site.example.com/a", into: database)
        try await insert(UUID(5), url: "https://myxsite.example.com/a", into: database)

        #expect(try await lookup("https://my_site.example.com/a", in: database) == id)
    }

    // MARK: - Empty queue

    @Test
    func claimingFromAnEmptyQueueReturnsNothing() async throws {
        let database = try makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 1000)

        #expect(try await repository.claimNextIngestionJob(now) == nil)
        #expect(try await repository.claimNextIngestionJobOfKind(.hydrateText, now) == nil)

        // Finished and failed jobs are not work either.
        try await database.write { db in
            try IngestionJobLocalTable.insert {
                IngestionJobLocalTable(id: UUID(1), payload: "done", processedAt: now, status: "completed")
                IngestionJobLocalTable(id: UUID(2), payload: "failed", status: "failed", attemptCount: 3)
            }
            .execute(db)
        }
        #expect(try await repository.claimNextIngestionJob(now) == nil)
    }
}
