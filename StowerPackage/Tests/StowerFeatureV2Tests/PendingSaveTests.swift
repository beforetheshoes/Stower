import ComposableArchitecture
import Foundation
import SQLiteData
@testable import StowerData
@testable import StowerFeature
import Testing

/// A save is listed from the moment it is queued until its article exists.
@Suite
struct PendingSaveTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func pending(in database: any DatabaseWriter) async throws -> [PendingSave] {
        try await database.read { db in try PendingSavesRequest().fetch(db) }
    }

    @Test
    func aQueuedURLIsPendingUntilItsJobCompletes() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/article")
            let queued = try await pending(in: database)
            #expect(queued.map(\.payload) == ["https://example.com/article"])
            #expect(queued.first?.isProcessing == false)

            let job = try #require(try await repository.claimNextIngestionJob(now))
            #expect(try await pending(in: database).first?.isProcessing == true)

            try await repository.completeIngestionJob(job.id, now)
            #expect(try await pending(in: database).isEmpty)
        }
    }

    @Test
    func aFailedSaveStopsBeingPending() async throws {
        let database = try StowerDatabase.makeDatabase()
        try await database.write { db in
            try IngestionJobLocalTable.insert {
                IngestionJobLocalTable(
                    id: UUID(1),
                    kind: IngestionJob.Kind.url.rawValue,
                    payload: "https://example.com/gone",
                    status: IngestionJob.Status.failed.rawValue
                )
            }
            .execute(db)
        }
        #expect(try await pending(in: database).isEmpty)
    }

    @Test
    func onlyKindsThatBecomeALibraryItemAreListedNewestFirst() async throws {
        let database = try StowerDatabase.makeDatabase()
        let kinds: [IngestionJob.Kind] = [.url, .pdf, .text, .uploadAsset, .hydrate, .epub]
        try await database.write { db in
            for (offset, kind) in kinds.enumerated() {
                try IngestionJobLocalTable.insert {
                    IngestionJobLocalTable(
                        id: UUID(offset),
                        kind: kind.rawValue,
                        payload: "payload-\(offset)",
                        createdAt: Date(timeIntervalSince1970: Double(offset))
                    )
                }
                .execute(db)
            }
        }
        #expect(try await pending(in: database).map(\.kind) == [.epub, .pdf, .url])
    }

    @Test
    func aSaveWhoseArticleHasArrivedIsNotListedTwice() {
        let saves = [
            PendingSave(
                id: UUID(1), kind: .url, payload: "https://Example.com/a#section", isProcessing: true, createdAt: now
            ),
            PendingSave(id: UUID(2), kind: .url, payload: "https://example.com/b", isProcessing: false, createdAt: now),
            PendingSave(id: UUID(3), kind: .pdf, payload: "/staging/file.pdf", isProcessing: false, createdAt: now),
        ]
        let arrived = SavedItem(
            title: "A", content: "Body", sourceURL: "https://example.com/a", createdAt: now.addingTimeInterval(5)
        )

        #expect(PendingSave.notYetArrived(saves, among: [arrived]).map(\.id) == [UUID(2), UUID(3)])
        #expect(PendingSave.notYetArrived(saves, among: []).count == 3)
    }

    @Test
    func savingAnArticleAgainIsListedWhileItRefreshes() {
        let save = PendingSave(
            id: UUID(1), kind: .url, payload: "https://example.com/a", isProcessing: true, createdAt: now
        )
        let existing = SavedItem(
            title: "A", content: "Body", sourceURL: "https://example.com/a", createdAt: now.addingTimeInterval(-500)
        )
        #expect(PendingSave.notYetArrived([save], among: [existing]) == [save])
    }

    @Test
    func pendingSavesShowOnlyInListsANewSaveLandsIn() {
        var state = LibraryFeature.State()
        for filter in [LibraryFilter.all, .unread, .untagged] {
            state.filter = filter
            #expect(state.showsPendingSaves)
        }
        for filter in [LibraryFilter.read, .starred, .recentlyDeleted, .tag(UUID(1))] {
            state.filter = filter
            #expect(!state.showsPendingSaves)
        }
        state.filter = .unread
        state.query = "search"
        #expect(!state.showsPendingSaves)
    }
}
