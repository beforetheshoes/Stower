import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
import Testing

/// Repository endpoints that had no direct coverage.
@Suite
struct RepositoryEndpointTests {
    private let now = Date(timeIntervalSince1970: 30_000)

    private func makeRepository() throws -> (any DatabaseWriter, StowerRepository) {
        let database = try StowerDatabase.makeDatabase()
        return (database, StowerRepository.live(database: database, cloudSyncClient: .noop))
    }

    // MARK: - Tags

    @Test
    func renamingATagChangesItsNameAndKeepsItsAssignments() async throws {
        let (_, repository) = try makeRepository()
        let item = try await repository.createItemFromIngestion(.sharedText("Tagged"))
        let tag = try await repository.createTag("Wrok", nil)
        try await repository.addTag(item.id, tag.id)

        try await repository.renameTag(tag.id, "Work")

        let tags = try await repository.fetchTags()
        #expect(tags.map(\.name) == ["Work"])
        #expect(tags.first?.id == tag.id)
        #expect(try await repository.fetchTagIDs(item.id) == [tag.id])
    }

    @Test
    func removingATagFromAnItemLeavesTheTagAndOtherItemsAlone() async throws {
        let (_, repository) = try makeRepository()
        let first = try await repository.createItemFromIngestion(.sharedText("First"))
        let second = try await repository.createItemFromIngestion(.sharedText("Second"))
        let tag = try await repository.createTag("Shared", nil)
        try await repository.addTag(first.id, tag.id)
        try await repository.addTag(second.id, tag.id)

        try await repository.removeTag(first.id, tag.id)

        #expect(try await repository.fetchTagIDs(first.id).isEmpty)
        #expect(try await repository.fetchTagIDs(second.id) == [tag.id])
        #expect(try await repository.fetchTags().map(\.id) == [tag.id])
    }

    @Test
    func tagIDsAreGroupedByItemAndUntaggedItemsAreAbsent() async throws {
        let (_, repository) = try makeRepository()
        let tagged = try await repository.createItemFromIngestion(.sharedText("Tagged"))
        let untagged = try await repository.createItemFromIngestion(.sharedText("Untagged"))
        let one = try await repository.createTag("One", nil)
        let two = try await repository.createTag("Two", nil)
        try await repository.addTag(tagged.id, one.id)
        try await repository.addTag(tagged.id, two.id)

        let byItem = try await repository.fetchTagIDsByItem([tagged.id, untagged.id])

        #expect(Set(byItem[tagged.id] ?? []) == [one.id, two.id])
        #expect(byItem[untagged.id] == nil)
        #expect(try await repository.fetchTagIDsByItem([]).isEmpty)
    }

    // MARK: - Settings

    @Test
    func imageSettingsRoundTripAndTheLastSaveWins() async throws {
        let (_, repository) = try makeRepository()

        try await repository.saveSettings(ImageDownloadSettings(globalAutoDownload: true, askForNewSources: false))
        try await repository.saveSettings(ImageDownloadSettings(globalAutoDownload: false, askForNewSources: false))

        let loaded = try await repository.loadSettings()
        #expect(loaded.globalAutoDownload == false)
        #expect(loaded.askForNewSources == false)
    }

    // MARK: - Local content

    @Test
    func localContentStatusIsRecordedWithItsError() async throws {
        let (database, repository) = try makeRepository()
        let item = try await repository.createItemFromIngestion(.sharedText("Body"))

        try await repository.updateLocalContentStatus(item.id, "failed", "The page could not be loaded.")

        let row = try await database.read { db in
            try SavedItemContentLocalTable.find(item.id).fetchOne(db)
        }
        #expect(row?.localStatus == "failed")
        #expect(row?.localError == "The page could not be loaded.")

        try await repository.updateLocalContentStatus(item.id, "available", nil)
        let cleared = try await database.read { db in
            try SavedItemContentLocalTable.find(item.id).fetchOne(db)
        }
        #expect(cleared?.localStatus == "available")
        #expect(cleared?.localError == nil)
    }

    @Test
    func updatingTheStatusOfAnItemWithNoContentRowDoesNothing() async throws {
        let (database, repository) = try makeRepository()

        try await repository.updateLocalContentStatus(UUID(404), "failed", "nope")

        let count = try await database.read { db in try SavedItemContentLocalTable.fetchCount(db) }
        #expect(count == 0)
    }

    @Test
    func mediaIsStoredOncePerSource() async throws {
        let (database, repository) = try makeRepository()
        let item = try await repository.createItemFromIngestion(.sharedText("Body"))
        let media = [
            MediaDescriptor(kind: .image, sourceURL: "https://example.com/a.jpg"),
            MediaDescriptor(kind: .image, sourceURL: "https://example.com/b.jpg"),
        ]

        try await repository.upsertMedia(media, item.id)
        // Re-ingesting the same article offers the same media again.
        try await repository.upsertMedia(media, item.id)

        let sources = try await database.read { db in
            try SavedMediaLocalTable
                .where { $0.itemID.eq(item.id) }
                .order { $0.sourceURL }
                .select(\.sourceURL)
                .fetchAll(db)
        }
        #expect(sources == ["https://example.com/a.jpg", "https://example.com/b.jpg"])
    }

    // MARK: - Failed imports

    @Test
    func dismissedFailuresLeaveTheListAndAreNotRetried() async throws {
        let (_, repository) = try makeRepository()
        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/broken")
        }
        for _ in 0..<3 {
            let job = try #require(try await repository.claimNextIngestionJob(now))
            try await repository.failIngestionJob(job.id, "Could not load.", now)
        }
        #expect(try await repository.fetchFailedIngestionJobs().count == 1)

        try await repository.dismissFailedIngestionJobs(now)

        #expect(try await repository.fetchFailedIngestionJobs().isEmpty)
        try await repository.retryFailedIngestionJobs()
        #expect(try await repository.claimNextIngestionJob(now) == nil)
    }
}
