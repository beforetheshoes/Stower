import Dependencies
import Foundation
import SQLiteData
@testable import StowerData
import Testing

/// The post-sync hydration scans run after every CloudKit sync. Each one
/// scans in a read and writes only for items that have nothing to render, so
/// these cover both halves: the first pass hydrates, the second finds nothing.
@Suite
struct SyncHydrationScanTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func makeRepository() throws -> (any DatabaseWriter, StowerRepository) {
        let database = try StowerDatabase.makeDatabase()
        return (database, StowerRepository.live(database: database, cloudSyncClient: .noop))
    }

    private func insertItem(_ id: UUID, into database: any DatabaseWriter) async throws {
        try await database.write { db in
            try SavedItemSyncTable.insert { SavedItemSyncTable(id: id, title: "Synced") }.execute(db)
        }
    }

    // MARK: - PDF

    @Test
    func pdfContentIsCopiedOnceAndThenLeftAlone() async throws {
        let (database, repository) = try makeRepository()
        let id = UUID(1)
        try await insertItem(id, into: database)
        try await database.write { db in
            try SavedPDFContentSyncTable.insert {
                SavedPDFContentSyncTable(id: id, documentJSON: #"{"blocks":[]}"#, plainText: "pdf text")
            }
            .execute(db)
        }

        try await withDependencies {
            $0.date.now = now
        } operation: {
            let first = try await repository.hydratePDFItemsFromSyncedContent()
            let second = try await repository.hydratePDFItemsFromSyncedContent()
            #expect(first == 1)
            #expect(second == 0)
        }

        let local = try await database.read { db in
            try SavedItemContentLocalTable.find(id).fetchOne(db)
        }
        #expect(local?.documentJSON == #"{"blocks":[]}"#)
        #expect(local?.plainText == "pdf text")
        #expect(local?.localStatus == "available")
    }

    @Test
    func pdfScanFillsAnEmptyPlaceholderButNeverClobbersLocalContent() async throws {
        let (database, repository) = try makeRepository()
        let placeholderID = UUID(1)
        let ingestedID = UUID(2)
        try await database.write { db in
            for id in [placeholderID, ingestedID] {
                try SavedItemSyncTable.insert { SavedItemSyncTable(id: id, title: "Synced") }.execute(db)
                try SavedPDFContentSyncTable.insert {
                    SavedPDFContentSyncTable(id: id, documentJSON: "synced", plainText: "synced")
                }
                .execute(db)
            }
            try SavedItemContentLocalTable.insert {
                SavedItemContentLocalTable(itemID: placeholderID, documentJSON: "")
            }
            .execute(db)
            try SavedItemContentLocalTable.insert {
                SavedItemContentLocalTable(itemID: ingestedID, documentJSON: "local")
            }
            .execute(db)
        }

        let hydrated = try await withDependencies {
            $0.date.now = now
        } operation: {
            try await repository.hydratePDFItemsFromSyncedContent()
        }
        #expect(hydrated == 1)

        let documents = try await database.read { db in
            try SavedItemContentLocalTable
                .select { ($0.itemID, $0.documentJSON) }
                .fetchAll(db)
        }
        #expect(Dictionary(uniqueKeysWithValues: documents) == [placeholderID: "synced", ingestedID: "local"])
    }

    // MARK: - Text

    @Test
    func textItemIsQueuedForHydrationOnce() async throws {
        let (database, repository) = try makeRepository()
        let id = UUID(1)
        try await insertItem(id, into: database)
        try await database.write { db in
            try SavedTextContentSyncTable.insert {
                SavedTextContentSyncTable(
                    id: id,
                    plainText: "excerpt",
                    rawSourceText: TextSyncCompression.compress("# Heading\n\nBody")
                )
            }
            .execute(db)
        }

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            let first = try await repository.hydrateTextItemsFromSyncedContent()
            // The job is still waiting: a second sync must not queue another.
            let second = try await repository.hydrateTextItemsFromSyncedContent()
            #expect(first == 1)
            #expect(second == 0)
        }

        let (jobs, status) = try await database.read { db in
            (
                try IngestionJobLocalTable
                    .where { $0.kind.eq(IngestionJob.Kind.hydrateText.rawValue) }
                    .fetchCount(db),
                try SavedItemContentLocalTable.find(id).fetchOne(db)?.localStatus
            )
        }
        #expect(jobs == 1)
        #expect(status == "downloading")
    }

    @Test
    func textContentWithoutAnItemRowIsSkipped() async throws {
        // Content rows can arrive from CloudKit before their item row.
        let (database, repository) = try makeRepository()
        try await database.write { db in
            try SavedTextContentSyncTable.insert {
                SavedTextContentSyncTable(id: UUID(1), plainText: "excerpt", rawSourceText: "raw")
            }
            .execute(db)
        }

        let enqueued = try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.hydrateTextItemsFromSyncedContent()
        }
        #expect(enqueued == 0)
    }

    // MARK: - Website

    @Test
    func websiteIsQueuedOnlyWhenItsArchiveIsMissingAndNotOffloaded() async throws {
        let (database, _) = try makeRepository()
        let missingID = UUID(1)
        let unpackedID = UUID(2)
        let offloadedID = UUID(3)
        let emptyID = UUID(4)
        let orphanID = UUID(5)
        try await database.write { db in
            for id in [missingID, unpackedID, offloadedID, emptyID] {
                try SavedItemSyncTable.insert { SavedItemSyncTable(id: id, title: "Site") }.execute(db)
            }
            for id in [missingID, unpackedID, offloadedID, orphanID] {
                try SavedWebsiteArchiveSyncTable.insert {
                    SavedWebsiteArchiveSyncTable(id: id, zipData: Data([1]), byteCount: 1)
                }
                .execute(db)
            }
            try SavedWebsiteArchiveSyncTable.insert {
                SavedWebsiteArchiveSyncTable(id: emptyID, byteCount: 0)
            }
            .execute(db)
            try ItemStorageLocalTable.insert {
                ItemStorageLocalTable(itemID: offloadedID, offloadedAt: now)
            }
            .execute(db)
        }
        let checked = LockIsolated<[UUID]>([])
        let scan = StowerRepository._hydrateWebsiteItemsFromSyncedContent(database: database) { id in
            checked.withValue { $0.append(id) }
            return id == unpackedID
        }

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            let first = try await scan()
            let second = try await scan()
            #expect(first == 1)
            #expect(second == 0)
        }

        // Offloaded, empty and orphaned archives never reach the disk check.
        #expect(Set(checked.value) == [missingID, unpackedID])
        let payloads = try await database.read { db in
            try IngestionJobLocalTable
                .where { $0.kind.eq(IngestionJob.Kind.hydrateWebsite.rawValue) }
                .select(\.payload)
                .fetchAll(db)
        }
        #expect(payloads.count == 1)
        #expect(payloads.first?.contains(missingID.uuidString) == true)
    }

    // MARK: - Tags

    @Test
    func orphanedTagAssignmentsAreRemovedAndLiveOnesKept() async throws {
        let (database, repository) = try makeRepository()
        let item = try await repository.createItemFromIngestion(.sharedText("Tagged"))
        let kept = try await repository.createTag("Kept", nil)
        let deleted = try await repository.createTag("Deleted", nil)
        try await repository.addTag(item.id, kept.id)
        try await repository.addTag(item.id, deleted.id)
        try await database.write { db in
            try TagSyncTable.find(deleted.id).delete().execute(db)
            // An assignment whose item never arrived.
            try ItemTagSyncTable.insert {
                ItemTagSyncTable(id: UUID(50), itemID: UUID(51), tagID: kept.id)
            }
            .execute(db)
        }

        #expect(try await repository.reconcileOrphanedTagAssignments() == 2)
        #expect(try await repository.reconcileOrphanedTagAssignments() == 0)
        #expect(try await repository.fetchTagIDs(item.id) == [kept.id])
    }
}
