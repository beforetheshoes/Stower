import ComposableArchitecture
import Dependencies
import Foundation
import GRDB
@testable import StowerData
@testable import StowerFeature
import Testing

/// The shipped build was terminated by iOS with `0xDEAD10CC` — it still held a
/// write lock on the App Group database when it was suspended. The crash landed
/// inside `enqueueHydrationJobsForMissingContent`, called from the periodic
/// CloudKit sync, which runs in the background.
///
/// These cover the parts of the fix that are checkable without backgrounding a
/// real app.
@Suite
struct DatabaseSuspensionTests {
    // MARK: - Configuration

    @Test
    func databaseObservesSuspensionNotifications() throws {
        // Without this the suspend notification does nothing and the process
        // keeps taking locks right up to the moment iOS kills it.
        let database = try StowerDatabase.makeDatabase()
        #expect(database.configuration.observesSuspensionNotifications)
    }

    @Test
    func suspensionAppliesOnlyWhereTheOSSuspendsProcesses() {
        // macOS has no 0xDEAD10CC, and suspending there would interrupt the
        // periodic background sync a Mac app is expected to keep running.
        #if os(iOS)
        #expect(DatabaseSuspensionObserver.isSupported)
        #else
        #expect(!DatabaseSuspensionObserver.isSupported)
        #endif
    }

    // MARK: - Recognising suspension errors

    @Test
    func interruptAndAbortAreRecognisedAsSuspension() {
        #expect(DatabaseError(resultCode: .SQLITE_INTERRUPT).isSuspended)
        #expect(DatabaseError(resultCode: .SQLITE_ABORT).isSuspended)
        #expect((DatabaseError(resultCode: .SQLITE_INTERRUPT) as Error).isDatabaseSuspension)
    }

    @Test
    func ordinaryDatabaseErrorsAreNotSuspension() {
        #expect(!DatabaseError(resultCode: .SQLITE_CONSTRAINT).isSuspended)
        #expect(!DatabaseError(resultCode: .SQLITE_CORRUPT).isSuspended)
        #expect(!(URLError(.timedOut) as Error).isDatabaseSuspension)
    }

    // MARK: - Text backfill filters in SQL

    @Test
    func textBackfillOnlyLoadsTextItemsMissingASyncRow() async throws {
        // The second TestFlight termination caught this scan loading every
        // content row in full inside a write transaction. Every filter now
        // runs in SQL, so the rows that come off disk are the ones that get
        // a sync row — and a second run finds none.
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 1000)
        let textID = UUID()
        let urlID = UUID()
        let pdfID = UUID()
        let syncedID = UUID()
        let offloadedID = UUID()

        try await database.write { db in
            let items: [(UUID, String?)] = [
                (textID, nil), (urlID, "https://example.com/a"), (pdfID, ""), (syncedID, nil), (offloadedID, nil),
            ]
            for (id, url) in items {
                try SavedItemSyncTable
                    .insert {
                        SavedItemSyncTable.Draft(id: id, title: "T", sourceURL: url, createdAt: now, updatedAt: now)
                    }
                    .execute(db)
            }
            let locals = [
                SavedItemContentLocalTable.Draft(itemID: textID, renderFormat: "structuredV1", plainText: "# Hello", localStatus: "available"),
                SavedItemContentLocalTable.Draft(itemID: urlID, renderFormat: "structuredV1", plainText: "web", localStatus: "available"),
                SavedItemContentLocalTable.Draft(itemID: pdfID, renderFormat: "pdf", plainText: "", localStatus: "available"),
                SavedItemContentLocalTable.Draft(itemID: syncedID, renderFormat: "plainText", plainText: "already", localStatus: "available"),
                SavedItemContentLocalTable.Draft(itemID: offloadedID, renderFormat: "plainText", plainText: "gone", localStatus: "notDownloaded"),
            ]
            for var local in locals {
                local.rawSourceText = local.plainText
                local.createdAt = now
                local.updatedAt = now
                try SavedItemContentLocalTable.insert { local }.execute(db)
            }
            try SavedTextContentSyncTable
                .insert {
                    SavedTextContentSyncTable.Draft(
                        id: syncedID,
                        plainText: "already",
                        rawSourceText: TextSyncCompression.compress("already"),
                        renderFormat: "plainText",
                        createdAt: now,
                        updatedAt: now
                    )
                }
                .execute(db)
        }

        let backfilled = try await withDependencies {
            $0.date.now = now
        } operation: {
            try await repository.backfillTextSyncTable()
        }
        #expect(backfilled == 1)

        let syncRows = try await database.read { db in
            try SavedTextContentSyncTable.select(\.id).fetchAll(db)
        }
        #expect(Set(syncRows) == [textID, syncedID])

        let again = try await withDependencies {
            $0.date.now = now
        } operation: {
            try await repository.backfillTextSyncTable()
        }
        #expect(again == 0)
    }

    // MARK: - Hydration scan no longer holds a write lock to read

    @Test
    func hydrationScanDoesNoWriteWhenNothingIsMissing() async throws {
        // The crash was a write transaction wrapping two full-table scans. With
        // nothing to hydrate there is now no write transaction at all, so the
        // common background case never takes a write lock.
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        try await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 1000)
            $0.uuid = .incrementing
        } operation: {
            let item = try await repository.createItemFromIngestion(
                .sharedText("An article with local content already present.")
            )
            #expect(item.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        }

        let enqueued = try await repository.enqueueHydrationJobsForMissingContent()
        #expect(enqueued == 0)
    }

    @Test
    func hydrationScanStillEnqueuesForItemsMissingContent() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let itemID = UUID()

        // A synced row with a source URL and no local content — what arrives on
        // a second device via CloudKit.
        try await database.write { db in
            try SavedItemSyncTable
                .insert {
                    SavedItemSyncTable.Draft(
                        id: itemID,
                        title: "Synced from another device",
                        sourceURL: "https://example.com/article",
                        createdAt: Date(timeIntervalSince1970: 1000),
                        updatedAt: Date(timeIntervalSince1970: 1000)
                    )
                }
                .execute(db)
        }

        let enqueued = try await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 2000)
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueHydrationJobsForMissingContent()
        }
        #expect(enqueued == 1)

        // And it is idempotent — the re-check inside the write stops a second
        // run from double-inserting.
        let again = try await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 3000)
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueHydrationJobsForMissingContent()
        }
        #expect(again == 0)
    }
}

/// A suspended database must not be reported to the user as a broken import.
@MainActor
@Suite
struct SuspensionDoesNotBecomeUserFacingFailureTests {
    @Test
    func suspendedImportIsNotRecordedAsAFailure() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 5000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        }

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.stowerRepository = repository
            $0.date.now = now
            $0.ingestionCoordinator = .init { try await $0() }
            // The article save fails the way a backgrounded app fails.
            $0.articleSaveClient.save = { _ in
                throw DatabaseError(resultCode: .SQLITE_INTERRUPT, message: "Database is suspended")
            }
            $0.cloudSyncClient = .noop
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.sceneDidBecomeActive)
        await store.receive(\.failedImportsLoaded)

        // The job must not be marked failed — nothing is wrong with it.
        let failures = try await repository.fetchFailedIngestionJobs()
        #expect(failures.isEmpty)
        #expect(store.state.failedImports.isEmpty)
    }
}
