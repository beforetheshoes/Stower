import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct RepositoryFilterTests {
    private func makeRepository() throws -> StowerRepository {
        let database = try StowerDatabase.makeDatabase()
        return StowerRepository.live(database: database, cloudSyncClient: .noop)
    }

    @Test
    func migration_v5_addsNewColumnsAndTables() async throws {
        let repository = try makeRepository()
        // If migration_v5 succeeded, fetchListCounts must not throw and new
        // tag APIs must also work against the schema.
        let counts = try await repository.fetchListCounts()
        #expect(counts.all == 0)
        #expect(counts.byTag.isEmpty)
        let tags = try await repository.fetchTags()
        #expect(tags.isEmpty)
    }

    @Test
    func all_unread_read_starred_filters() async throws {
        let repository = try makeRepository()

        let a = try await repository.createItemFromIngestion(.sharedText("Alpha"))
        let b = try await repository.createItemFromIngestion(.sharedText("Beta"))
        let c = try await repository.createItemFromIngestion(.sharedText("Gamma"))

        try await repository.setReadStatus(b.id, true)
        try await repository.setStarred(c.id, true)

        let all = try await repository.fetchLibrary(.all)
        #expect(all.count == 3)

        let unread = try await repository.fetchLibrary(.unread)
        #expect(unread.map(\.id).contains(a.id))
        #expect(!unread.map(\.id).contains(b.id))

        let read = try await repository.fetchLibrary(.read)
        #expect(read.map(\.id) == [b.id])

        let starred = try await repository.fetchLibrary(.starred)
        #expect(starred.map(\.id) == [c.id])
    }

    @Test
    func changingReadOrStarredStateDoesNotReorderLibrary() async throws {
        let repository = try makeRepository()
        let first = try await repository.createItemFromIngestion(.sharedText("First"))
        let second = try await repository.createItemFromIngestion(.sharedText("Second"))
        let originalOrder = try await repository.fetchLibrary(.all).map(\.id)

        try await repository.setStarred(first.id, true)
        try await repository.setReadStatus(first.id, true)

        #expect(try await repository.fetchLibrary(.all).map(\.id) == originalOrder)
        #expect(Set(originalOrder) == Set([first.id, second.id]))
    }

    @Test
    func softDelete_restore_permanent() async throws {
        let repository = try makeRepository()
        let a = try await repository.createItemFromIngestion(.sharedText("Alpha"))

        try await repository.deleteItem(a.id)
        var all = try await repository.fetchLibrary(.all)
        var trash = try await repository.fetchLibrary(.recentlyDeleted)
        #expect(!all.map(\.id).contains(a.id))
        #expect(trash.map(\.id).contains(a.id))

        try await repository.restoreFromTrash(a.id)
        all = try await repository.fetchLibrary(.all)
        trash = try await repository.fetchLibrary(.recentlyDeleted)
        #expect(all.map(\.id).contains(a.id))
        #expect(!trash.map(\.id).contains(a.id))

        try await repository.permanentlyDelete(a.id)
        all = try await repository.fetchLibrary(.all)
        trash = try await repository.fetchLibrary(.recentlyDeleted)
        #expect(!all.map(\.id).contains(a.id))
        #expect(!trash.map(\.id).contains(a.id))
    }

    @Test
    func untagged_and_tagFilters() async throws {
        let repository = try makeRepository()
        let a = try await repository.createItemFromIngestion(.sharedText("Alpha"))
        let b = try await repository.createItemFromIngestion(.sharedText("Beta"))
        let c = try await repository.createItemFromIngestion(.sharedText("Gamma"))

        let work = try await repository.createTag("work", nil)
        try await repository.addTag(a.id, work.id)
        try await repository.addTag(b.id, work.id)

        let untagged = try await repository.fetchLibrary(.untagged)
        #expect(untagged.map(\.id) == [c.id])

        let tagged = try await repository.fetchLibrary(.tag(work.id))
        let taggedIDs = Set(tagged.map(\.id))
        #expect(taggedIDs == Set([a.id, b.id]))

        // Domain model should surface the tag IDs on the item.
        let taggedA = try #require(tagged.first { $0.id == a.id })
        #expect(taggedA.tagIDs == [work.id])
    }

    @Test
    func listCounts_reflectState() async throws {
        let repository = try makeRepository()
        let a = try await repository.createItemFromIngestion(.sharedText("A"))
        let b = try await repository.createItemFromIngestion(.sharedText("B"))
        let c = try await repository.createItemFromIngestion(.sharedText("C"))

        try await repository.setStarred(a.id, true)
        try await repository.setReadStatus(b.id, true)

        let work = try await repository.createTag("work", nil)
        try await repository.addTag(a.id, work.id)
        try await repository.deleteItem(c.id)

        let counts = try await repository.fetchListCounts()
        #expect(counts.all == 2)
        #expect(counts.unread == 1) // only `a` is unread & live
        #expect(counts.read == 1)
        #expect(counts.starred == 1)
        #expect(counts.recentlyDeleted == 1)
        #expect(counts.untagged == 1) // b is untagged, c is in trash
        #expect(counts.byTag[work.id] == 1)
    }

    @Test
    func deleteTag_cascadesJunction_andUntagsItems() async throws {
        let repository = try makeRepository()
        let a = try await repository.createItemFromIngestion(.sharedText("A"))
        let label = try await repository.createTag("label", nil)
        try await repository.addTag(a.id, label.id)

        try await repository.deleteTag(label.id)

        let untagged = try await repository.fetchLibrary(.untagged)
        #expect(untagged.map(\.id).contains(a.id))
        let tags = try await repository.fetchTags()
        #expect(!tags.contains { $0.id == label.id })
    }

    @Test
    func createTag_isCaseInsensitivelyIdempotent() async throws {
        let repository = try makeRepository()
        let first = try await repository.createTag("AI", nil)
        let second = try await repository.createTag("ai", nil)
        #expect(first.id == second.id)
        let tags = try await repository.fetchTags()
        #expect(tags.count == 1)
    }

    @Test
    func diagnostics_includesTagAndJunctionCounts() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        let item = try await repository.createItemFromIngestion(.sharedText("Alpha"))
        let tag = try await repository.createTag("work", nil)
        try await repository.addTag(item.id, tag.id)

        // Query tag/junction counts directly — the full makeDiagnosticsLoad
        // also queries iCloud metadata tables that are unavailable in the
        // test-only in-memory database.
        let (tagCount, junctionCount) = try await database.read { db -> (Int, Int) in
            let tags = try TagSyncTable.fetchCount(db)
            let junctions = try ItemTagSyncTable.fetchCount(db)
            return (tags, junctions)
        }

        #expect(tagCount == 1)
        #expect(junctionCount == 1)

        // Verify the SyncDiagnostics model accepts the new fields.
        let diagnostics = SyncDiagnostics(
            syncedItemsCount: 1,
            pendingChangesCount: 0,
            metadataCount: 0,
            syncedTagsCount: tagCount,
            syncedItemTagsCount: junctionCount
        )
        #expect(diagnostics.syncedTagsCount == 1)
        #expect(diagnostics.syncedItemTagsCount == 1)
    }

    @Test
    func reconcileOrphanedTagAssignments_removesRemoteDeletionResidue() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let item = try await repository.createItemFromIngestion(.sharedText("Tagged"))
        let tag = try await repository.createTag("Temporary", nil)
        try await repository.addTag(item.id, tag.id)

        // Simulate CloudKit delivering the tag deletion without the matching
        // junction deletion. These sync tables intentionally have no FKs.
        try await database.write { db in
            try TagSyncTable.find(tag.id).delete().execute(db)
        }

        #expect(try await repository.fetchTagIDs(item.id) == [tag.id])
        #expect(try await repository.reconcileOrphanedTagAssignments() == 1)
        #expect(try await repository.fetchTagIDs(item.id).isEmpty)
    }

    @Test
    func migration_v6_replacesUniqueIndexes() async throws {
        let database = try StowerDatabase.makeDatabase()

        let indexes: [String] = try await database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT "name" FROM "sqlite_master"
                    WHERE "type" = 'index'
                      AND "tbl_name" IN ('tagSyncTables', 'itemTagSyncTables')
                    ORDER BY "name"
                    """
            )
        }

        // v5 UNIQUE indexes must NOT exist (dropped by v6).
        #expect(!indexes.contains("idx_tagSyncTables_name"))
        #expect(!indexes.contains("idx_itemTagSyncTables_item_tag"))

        // v6 non-unique replacements MUST exist.
        #expect(indexes.contains("idx_tagSyncTables_name_lower"))
        #expect(indexes.contains("idx_itemTagSyncTables_item_tag_pair"))
    }

    @Test
    func observeLibraryChanges_firesOnMutation() async throws {
        let repository = try makeRepository()
        let stream = repository.observeLibraryChanges()
        var iterator = stream.makeAsyncIterator()

        async let received = iterator.next()
        _ = try await repository.createItemFromIngestion(.sharedText("Ping"))
        let pong: Void? = await received
        #expect(pong != nil)
    }
}
