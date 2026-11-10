import Foundation
import GRDB
import SQLiteData
@testable import StowerData
import Testing

/// Every other test builds the schema from nothing. An installed copy takes a
/// different path: it already has rows when a new migration runs.
@Suite
struct MigrationUpgradeTests {
    @Test
    func migrationsAreRegisteredInAStableOrder() {
        let names = StowerDatabase.makeMigrator().migrations
        #expect(names.first == "create-stower-v2-reader")
        #expect(names.last == "add-library-sort-index")
        #expect(Set(names).count == names.count)
    }

    @Test
    func anExistingLibrarySurvivesTheLatestMigration() throws {
        let queue = try DatabaseQueue()
        let migrator = StowerDatabase.makeMigrator()

        // A database as it stood before the newest migration, with content.
        try migrator.migrate(queue, upTo: "add-progress-unit-count")
        let liveID = UUID(1)
        let trashedID = UUID(2)
        try queue.write { db in
            try SavedItemSyncTable.insert {
                SavedItemSyncTable(
                    id: liveID,
                    title: "Live",
                    createdAt: Date(timeIntervalSince1970: 100)
                )
                SavedItemSyncTable(
                    id: trashedID,
                    title: "Trashed",
                    createdAt: Date(timeIntervalSince1970: 200),
                    deletedAt: Date(timeIntervalSince1970: 300)
                )
            }
            .execute(db)
            try SavedItemContentLocalTable.insert {
                SavedItemContentLocalTable(itemID: liveID, documentJSON: #"{"blocks":[1,2,3]}"#)
            }
            .execute(db)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            #expect(try SavedItemSyncTable.fetchCount(db) == 2)
            let live = try LibraryQueries.fetchItems(db, filter: .all, query: "", oldestFirst: false)
            #expect(live.map(\.id) == [liveID])
            #expect(live.first?.progressUnitCount == 3)
            let trash = try LibraryQueries.fetchItems(db, filter: .recentlyDeleted, query: "", oldestFirst: false)
            #expect(trash.map(\.id) == [trashedID])
            #expect(try migrator.hasCompletedMigrations(db))
        }
    }
}
