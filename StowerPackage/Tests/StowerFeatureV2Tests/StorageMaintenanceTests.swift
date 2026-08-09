import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct StorageMaintenanceTests {
    @Test
    func clearDeadImageAssetBlobs_removesLegacyRows() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let client = StorageMaintenanceClient.live(database: database)

        // The legacy table has an FK to the item table, so anchor the blob
        // to a real item the way old app versions did.
        let item = try await repository.createItemFromIngestion(.sharedText("Legacy"))
        try await database.write { db in
            try SavedImageAssetLocalTable.insert {
                SavedImageAssetLocalTable(
                    id: UUID(),
                    itemID: item.id,
                    imageData: Data(repeating: 0xAB, count: 1024)
                )
            }
            .execute(db)
        }

        #expect(try await client.clearDeadImageAssetBlobs() == 1)
        let remaining = try await database.read { db in
            try SavedImageAssetLocalTable.fetchCount(db)
        }
        #expect(remaining == 0)
        // Re-running is a no-op.
        #expect(try await client.clearDeadImageAssetBlobs() == 0)
    }

    @Test
    func databaseStats_reportsPagesAndFreelist() async throws {
        let database = try StowerDatabase.makeDatabase()
        let client = StorageMaintenanceClient.live(database: database)

        let stats = try await client.databaseStats()
        #expect(stats.pageCount > 0)
        #expect(stats.pageSize > 0)
        #expect(stats.fileBytes == stats.pageCount * stats.pageSize)
        #expect(stats.reclaimableBytes == stats.freelistCount * stats.pageSize)
    }

    @Test
    func vacuum_reclaimsFreelistPagesAndPreservesRows() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let client = StorageMaintenanceClient.live(database: database)
        let item = try await repository.createItemFromIngestion(.sharedText("Bulky"))
        let keeper = UUID()

        try await database.write { db in
            try SavedImageAssetLocalTable.insert {
                SavedImageAssetLocalTable(
                    id: keeper,
                    itemID: item.id,
                    imageData: Data(repeating: 0x01, count: 64)
                )
            }
            .execute(db)
            try SavedImageAssetLocalTable.insert {
                SavedImageAssetLocalTable(
                    id: UUID(),
                    itemID: item.id,
                    imageData: Data(repeating: 0xFF, count: 5 * 1024 * 1024)
                )
            }
            .execute(db)
        }
        try await database.write { db in
            try SavedImageAssetLocalTable
                .where { $0.id.neq(keeper) }
                .delete()
                .execute(db)
        }

        let before = try await client.databaseStats()
        #expect(before.freelistCount > 0)

        try await client.checkpoint()
        try await client.vacuum()

        let after = try await client.databaseStats()
        #expect(after.freelistCount == 0)
        #expect(after.fileBytes < before.fileBytes)
        let survivors = try await database.read { db in
            try SavedImageAssetLocalTable.select(\.id).fetchAll(db)
        }
        #expect(survivors == [keeper])
    }

    @Test
    func activeJobPayloadPaths_includesOnlyRetryableFileJobs() async throws {
        let database = try StowerDatabase.makeDatabase()
        let client = StorageMaintenanceClient.live(database: database)

        try await database.write { db in
            try IngestionJobLocalTable.insert {
                IngestionJobLocalTable(id: UUID(), kind: "pdf", payload: "/pending/a.pdf", status: "queued")
                IngestionJobLocalTable(id: UUID(), kind: "website", payload: "/pending/site", status: "claimed")
                IngestionJobLocalTable(id: UUID(), kind: "pdf", payload: "/pending/b.pdf", status: "failed")
                IngestionJobLocalTable(id: UUID(), kind: "pdf", payload: "/pending/done.pdf", status: "completed")
                IngestionJobLocalTable(id: UUID(), kind: "url", payload: "https://example.com", status: "queued")
            }
            .execute(db)
        }

        let paths = try await client.activeJobPayloadPaths()
        #expect(paths == ["/pending/a.pdf", "/pending/site", "/pending/b.pdf"])
    }
}

@Suite
struct OrphanSweepTests {
    private func makeFixture() throws -> (database: any DatabaseWriter, repository: StowerRepository) {
        let database = try StowerDatabase.makeDatabase()
        return (database, StowerRepository.live(database: database, cloudSyncClient: .noop))
    }

    private func sweep(_ database: any DatabaseWriter, now: Date) async throws -> Int {
        try await withDependencies {
            $0.date = .constant(now)
        } operation: {
            try await StorageMaintenanceClient.live(database: database).sweepOrphanedSyncRows()
        }
    }

    @Test
    func orphanIsQuarantinedThenDeletedAfterWindow() async throws {
        let (database, _) = try makeFixture()
        let orphanID = UUID()
        try await database.write { db in
            try SavedWebsiteArchiveSyncTable.insert {
                SavedWebsiteArchiveSyncTable(id: orphanID, zipData: Data("zip".utf8))
            }
            .execute(db)
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // First pass quarantines but must not delete.
        #expect(try await sweep(database, now: start) == 0)
        var rows = try await database.read { db in
            try SavedWebsiteArchiveSyncTable.fetchCount(db)
        }
        #expect(rows == 1)

        // Second pass inside the window still must not delete.
        #expect(try await sweep(database, now: start.addingTimeInterval(24 * 3600)) == 0)

        // Past the quarantine window the row is removed.
        let afterWindow = start.addingTimeInterval(StorageMaintenanceClient.orphanQuarantineInterval + 60)
        #expect(try await sweep(database, now: afterWindow) == 1)
        rows = try await database.read { db in
            try SavedWebsiteArchiveSyncTable.fetchCount(db)
        }
        #expect(rows == 0)
        let candidates = try await database.read { db in
            try OrphanCandidateLocalTable.fetchCount(db)
        }
        #expect(candidates == 0)
    }

    @Test
    func liveItemsRowsAreNeverTouched() async throws {
        let (database, repository) = try makeFixture()
        let item = try await repository.createItemFromIngestion(.sharedText("Alive"))
        try await database.write { db in
            try SavedWebsiteArchiveSyncTable.insert {
                SavedWebsiteArchiveSyncTable(id: item.id, zipData: Data("zip".utf8))
            }
            .execute(db)
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try await sweep(database, now: start) == 0)
        let farFuture = start.addingTimeInterval(100 * 24 * 3600)
        #expect(try await sweep(database, now: farFuture) == 0)

        let rows = try await database.read { db in
            try SavedWebsiteArchiveSyncTable.fetchCount(db)
        }
        #expect(rows == 1)
    }

    @Test
    func candidateIsReleasedWhenItemRowArrivesLate() async throws {
        let (database, repository) = try makeFixture()
        let orphanID = UUID()
        try await database.write { db in
            try SavedPDFContentSyncTable.insert {
                SavedPDFContentSyncTable(id: orphanID, documentJSON: "{}", plainText: "pdf")
            }
            .execute(db)
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try await sweep(database, now: start) == 0)

        // Simulate the item row arriving from CloudKit after quarantine began.
        try await database.write { db in
            try SavedItemSyncTable.insert {
                SavedItemSyncTable(id: orphanID, title: "Late arrival")
            }
            .execute(db)
        }
        _ = try await repository.fetchLibrary(.all)

        let afterWindow = start.addingTimeInterval(StorageMaintenanceClient.orphanQuarantineInterval + 60)
        #expect(try await sweep(database, now: afterWindow) == 0)

        let rows = try await database.read { db in
            try SavedPDFContentSyncTable.fetchCount(db)
        }
        #expect(rows == 1)
        let candidates = try await database.read { db in
            try OrphanCandidateLocalTable
                .where { $0.orphanID.eq(orphanID) }
                .fetchCount(db)
        }
        #expect(candidates == 0)
    }

    @Test
    func orphanedCaptureManifestAndChunksAreSweptTogether() async throws {
        let (database, _) = try makeFixture()
        let orphanItemID = UUID()
        let captureID = UUID()
        try await database.write { db in
            try SavedArticleCaptureSyncTable.insert {
                SavedArticleCaptureSyncTable(id: UUID(), itemID: orphanItemID, captureID: captureID)
            }
            .execute(db)
            try SavedArticleCaptureChunkSyncTable.insert {
                SavedArticleCaptureChunkSyncTable(
                    id: UUID(),
                    itemID: orphanItemID,
                    captureID: captureID,
                    sequence: 0,
                    data: Data("chunk".utf8)
                )
                SavedArticleCaptureChunkSyncTable(
                    id: UUID(),
                    itemID: orphanItemID,
                    captureID: captureID,
                    sequence: 1,
                    data: Data("chunk2".utf8)
                )
            }
            .execute(db)
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try await sweep(database, now: start) == 0)
        let afterWindow = start.addingTimeInterval(StorageMaintenanceClient.orphanQuarantineInterval + 60)
        #expect(try await sweep(database, now: afterWindow) == 3)

        let (manifests, chunks) = try await database.read { db in
            (
                try SavedArticleCaptureSyncTable.fetchCount(db),
                try SavedArticleCaptureChunkSyncTable.fetchCount(db)
            )
        }
        #expect(manifests == 0)
        #expect(chunks == 0)
    }
}
