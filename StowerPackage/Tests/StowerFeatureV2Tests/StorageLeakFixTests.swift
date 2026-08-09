import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing

/// Permanent deletion must clear every content sync table keyed on the item's
/// ID. These tables have no foreign keys, so a missed delete leaves large
/// blobs (website zips especially) orphaned in the local database and in
/// CloudKit forever.
@Suite
struct StorageLeakFixTests {
    private func makeFixture() throws -> (database: any DatabaseWriter, repository: StowerRepository) {
        let database = try StowerDatabase.makeDatabase()
        return (database, StowerRepository.live(database: database, cloudSyncClient: .noop))
    }

    private func seedContentRows(for id: UUID, in database: any DatabaseWriter) async throws {
        try await database.write { db in
            try SavedWebsiteArchiveSyncTable.insert {
                SavedWebsiteArchiveSyncTable(
                    id: id,
                    zipData: Data("zip-bytes".utf8),
                    sha256: "abc",
                    originalFilename: "site.zip",
                    byteCount: 9
                )
            }
            .execute(db)
            try SavedPDFContentSyncTable.insert {
                SavedPDFContentSyncTable(id: id, documentJSON: "{}", plainText: "pdf text")
            }
            .execute(db)
            // Text items already write their own text sync row at creation, so
            // upsert rather than insert to keep the fixture independent of that.
            try SavedTextContentSyncTable.upsert {
                SavedTextContentSyncTable.Draft(id: id, plainText: "text", rawSourceText: "raw")
            }
            .execute(db)
            try SavedAssetManifestSyncTable.insert {
                SavedAssetManifestSyncTable(
                    id: UUID(),
                    itemID: id,
                    kind: "pdf",
                    recordName: "asset-record",
                    sha256: "abc"
                )
            }
            .execute(db)
            try ItemStorageLocalTable.insert {
                ItemStorageLocalTable(itemID: id)
            }
            .execute(db)
        }
    }

    private struct RowCounts {
        var website = 0
        var pdf = 0
        var text = 0
        var manifests = 0
        var storage = 0
    }

    private func contentRowCounts(for id: UUID, in database: any DatabaseWriter) async throws -> RowCounts {
        try await database.read { db in
            RowCounts(
                website: try SavedWebsiteArchiveSyncTable.where { $0.id.eq(id) }.fetchCount(db),
                pdf: try SavedPDFContentSyncTable.where { $0.id.eq(id) }.fetchCount(db),
                text: try SavedTextContentSyncTable.where { $0.id.eq(id) }.fetchCount(db),
                manifests: try SavedAssetManifestSyncTable.where { $0.itemID.eq(id) }.fetchCount(db),
                storage: try ItemStorageLocalTable.where { $0.itemID.eq(id) }.fetchCount(db)
            )
        }
    }

    @Test
    func permanentlyDelete_clearsContentSyncTables() async throws {
        let (database, repository) = try makeFixture()
        let item = try await repository.createItemFromIngestion(.sharedText("Doomed"))
        try await seedContentRows(for: item.id, in: database)

        try await repository.deleteItem(item.id)
        try await repository.permanentlyDelete(item.id)

        let counts = try await contentRowCounts(for: item.id, in: database)
        #expect(counts.website == 0)
        #expect(counts.pdf == 0)
        #expect(counts.text == 0)
        #expect(counts.manifests == 0)
        #expect(counts.storage == 0)
    }

    @Test
    func purgeOldTrash_clearsContentSyncTables() async throws {
        let (database, repository) = try makeFixture()
        let expired = try await repository.createItemFromIngestion(.sharedText("Old"))
        let fresh = try await repository.createItemFromIngestion(.sharedText("New"))
        try await seedContentRows(for: expired.id, in: database)
        try await seedContentRows(for: fresh.id, in: database)

        try await repository.deleteItem(expired.id)
        try await repository.deleteItem(fresh.id)
        // Back-date only the expired item past the 30-day retention window.
        try await database.write { db in
            try SavedItemSyncTable
                .find(expired.id)
                .update { $0.deletedAt = #bind(Date.now.addingTimeInterval(-31 * 24 * 3600) as Date?) }
                .execute(db)
        }

        let purged = try await repository.purgeOldTrash()
        #expect(purged == [expired.id])

        let expiredCounts = try await contentRowCounts(for: expired.id, in: database)
        #expect(expiredCounts.website == 0)
        #expect(expiredCounts.pdf == 0)
        #expect(expiredCounts.text == 0)
        #expect(expiredCounts.manifests == 0)
        #expect(expiredCounts.storage == 0)

        // The still-retained trash item keeps its content rows.
        let freshCounts = try await contentRowCounts(for: fresh.id, in: database)
        #expect(freshCounts.website == 1)
        #expect(freshCounts.pdf == 1)
        #expect(freshCounts.text == 1)
        #expect(freshCounts.manifests == 1)
        #expect(freshCounts.storage == 1)
    }
}
