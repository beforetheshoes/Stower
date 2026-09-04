import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct LibraryQueriesTests {
    @Test
    func progressUnitCountIsMaintainedByTriggers() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        let ingestion = IngestionResult.sharedText("One paragraph.\n\nTwo paragraphs.")
        let item = try await repository.createItemFromIngestion(ingestion)
        let blockCount = ingestion.document.blocks.count

        let stored = try await database.read { db in
            try SavedItemContentLocalTable.find(item.id).fetchOne(db)?.progressUnitCount
        }
        #expect(stored == blockCount)

        // The library row reports the count without decoding the document.
        let rows = try await database.read { db in
            try LibraryQueries.fetchItems(db, filter: .all, query: "", oldestFirst: false)
        }
        #expect(rows.first?.progressUnitCount == blockCount)

        // Rewriting the document updates the count through the update trigger.
        var replacement = IngestionResult.sharedText("Only one.")
        replacement.title = "Replacement"
        try await repository.hydrateItemContent(item.id, replacement)
        let updated = try await database.read { db in
            try SavedItemContentLocalTable.find(item.id).fetchOne(db)?.progressUnitCount
        }
        #expect(updated == replacement.document.blocks.count)
    }

    @Test
    func searchMatchesTitleMetadataAndBodyOnlyReturningBodyForMatches() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        var alpha = IngestionResult.sharedText("The quick brown fox jumps.")
        alpha.title = "Alpha"
        alpha.author = "Jane Author"
        let alphaItem = try await repository.createItemFromIngestion(alpha)

        var beta = IngestionResult.sharedText("Nothing relevant here.")
        beta.title = "Beta 100% Guide"
        _ = try await repository.createItemFromIngestion(beta)

        func search(_ query: String) async throws -> [SavedItem] {
            try await database.read { db in
                try LibraryQueries.fetchItems(db, filter: .all, query: query, oldestFirst: false)
            }
        }

        // Unfiltered rows never carry body text.
        let all = try await search("")
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.content.isEmpty })

        let byBody = try await search("brown fox")
        #expect(byBody.map(\.id) == [alphaItem.id])
        #expect(byBody[0].content.contains("brown fox"))

        let byAuthor = try await search("jane")
        #expect(byAuthor.map(\.id) == [alphaItem.id])

        // LIKE wildcards in user input are treated literally.
        let literalPercent = try await search("100%")
        #expect(literalPercent.map(\.title) == ["Beta 100% Guide"])
        let literalUnderscore = try await search("a_b")
        #expect(literalUnderscore.isEmpty)
    }

    @Test
    func filtersAndSortRunInSQL() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        var first = IngestionResult.sharedText("First body")
        first.title = "First"
        let firstItem = try await repository.createItemFromIngestion(first)
        var second = IngestionResult.sharedText("Second body")
        second.title = "Second"
        let secondItem = try await repository.createItemFromIngestion(second)
        let tag = try await repository.createTag("work", nil)
        try await repository.addTag(secondItem.id, tag.id)
        try await repository.setStarred(firstItem.id, true)

        func fetch(_ filter: LibraryFilter, oldestFirst: Bool = false) async throws -> [UUID] {
            try await database.read { db in
                try LibraryQueries.fetchItems(db, filter: filter, query: "", oldestFirst: oldestFirst)
            }
            .map(\.id)
        }

        #expect(try await fetch(.all) == [secondItem.id, firstItem.id])
        #expect(try await fetch(.all, oldestFirst: true) == [firstItem.id, secondItem.id])
        #expect(try await fetch(.starred) == [firstItem.id])
        #expect(try await fetch(.tag(tag.id)) == [secondItem.id])
        #expect(try await fetch(.untagged) == [firstItem.id])

        let counts = try await database.read { db in try LibraryQueries.fetchListCounts(db) }
        #expect(counts.all == 2)
        #expect(counts.starred == 1)
        #expect(counts.untagged == 1)
        #expect(counts.byTag[tag.id] == 1)
    }
}
