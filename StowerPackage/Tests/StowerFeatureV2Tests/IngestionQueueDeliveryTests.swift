import Dependencies
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

/// Coverage for the paths that let a shared URL vanish between the share
/// extension saying "Saved to Stower" and the item appearing in the library.
/// `.serialized` because the coordinator tests exercise the live gate, which
/// is a process-wide singleton.
@Suite(.serialized)
struct IngestionQueueDeliveryTests {
    // MARK: - Coordinator

    @Test
    func coordinatorRunsAnOperationThatArrivesDuringAnInFlightDrain() async throws {
        // The share extension can only enqueue a job; the main app drains the
        // queue. A capture takes tens of seconds, so a drain triggered by the
        // user returning to the app routinely overlaps one already running.
        // The coordinator used to await the in-flight drain and then return
        // *without running the new one*, leaving the just-shared URL queued.
        let recorder = RunRecorder()
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()

        try await withDependencies {
            // The test coordinator has no gate at all; this exercises the real one.
            $0.context = .live
        } operation: {
            let coordinator = currentIngestionCoordinator()

            async let first: Void = coordinator.run {
                await recorder.record("first-start")
                await firstStarted.signal()
                await releaseFirst.wait()
                await recorder.record("first-end")
            }

            await firstStarted.wait()

            async let second: Void = coordinator.run {
                await recorder.record("second")
            }

            await releaseFirst.signal()
            _ = try await (first, second)
        }

        #expect(await recorder.entries == ["first-start", "first-end", "second"])
    }

    @Test
    func coordinatorRunsTheNextOperationEvenAfterOneFails() async throws {
        let recorder = RunRecorder()
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()

        await withDependencies {
            $0.context = .live
        } operation: {
            let coordinator = currentIngestionCoordinator()

            async let first: Void = coordinator.run {
                await firstStarted.signal()
                await releaseFirst.wait()
                throw CocoaError(.fileNoSuchFile)
            }
            await firstStarted.wait()

            async let second: Void = coordinator.run {
                await recorder.record("second")
            }

            await releaseFirst.signal()
            _ = try? await first
            try? await second
        }

        #expect(await recorder.entries == ["second"])
    }

    // MARK: - Queue

    @Test
    func resharingTheSameURLDoesNotQueueASecondCapture() async throws {
        // Sharing a link that appears not to have worked is the natural user
        // response, and each attempt used to queue another full capture of the
        // same page.
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 3000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        }

        let first = try #require(try await repository.claimNextIngestionJob(now))
        #expect(first.payload == "https://example.com/post")
        #expect(try await repository.claimNextIngestionJob(now) == nil)
    }

    @Test
    func aDifferentURLIsStillQueuedSeparately() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 4000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/a")
            try await repository.enqueueIngestionJob(.url, "https://example.com/b")
        }

        let first = try #require(try await repository.claimNextIngestionJob(now))
        let second = try #require(try await repository.claimNextIngestionJob(now))
        #expect(Set([first.payload, second.payload]) == ["https://example.com/a", "https://example.com/b"])
    }

    @Test
    func theSameURLCanBeQueuedAgainOnceTheEarlierJobIsProcessed() async throws {
        // Dedup is scoped to unprocessed jobs so a later re-save still works.
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 5000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        }
        let first = try #require(try await repository.claimNextIngestionJob(now))
        try await repository.completeIngestionJob(first.id, now)

        try await withDependencies {
            $0.date.now = now.addingTimeInterval(60)
            // A fresh id — `.incrementing` restarts at UUID(0) and would
            // collide with the job enqueued above.
            $0.uuid = .constant(UUID(99))
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        }
        #expect(try await repository.claimNextIngestionJob(now.addingTimeInterval(60)) != nil)
    }

    @Test
    func resharingAURLWhoseImportFailedQueuesAFreshJob() async throws {
        // Re-saving is how the user retries a failed import. Dedup must not
        // swallow it, or the second attempt would do nothing at all.
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 7000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/hostile")
        }

        // Exhaust the retry budget so the job lands in `failed`.
        for attempt in 0..<3 {
            let job = try #require(try await repository.claimNextIngestionJob(now))
            try await repository.failIngestionJob(job.id, "attempt \(attempt) failed", now)
        }
        #expect(try await repository.claimNextIngestionJob(now) == nil)
        #expect(try await repository.fetchFailedIngestionJobs().count == 1)

        try await withDependencies {
            $0.date.now = now.addingTimeInterval(30)
            $0.uuid = .constant(UUID(77))
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/hostile")
        }

        let retried = try #require(
            try await repository.claimNextIngestionJob(now.addingTimeInterval(30))
        )
        #expect(retried.payload == "https://example.com/hostile")
    }

    @Test
    func repeatedTextSharesAreStillQueuedIndependently() async throws {
        // Text payloads are user content, not an identifier — saving the same
        // note twice on purpose must produce two items.
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 6000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.text, "a thought")
            try await repository.enqueueIngestionJob(.text, "a thought")
        }

        #expect(try await repository.claimNextIngestionJob(now) != nil)
        #expect(try await repository.claimNextIngestionJob(now) != nil)
    }
}

// MARK: - Helpers

/// Reads the coordinator out of the current dependency scope as a plain value.
/// Binding it through `@Dependency` directly leaves the compiler unable to
/// prove the accessor is safe to use from the concurrent `async let` children.
private func currentIngestionCoordinator() -> IngestionCoordinator {
    @Dependency(\.ingestionCoordinator)
    var coordinator
    return coordinator
}

private actor RunRecorder {
    var entries = [String]()
    func record(_ value: String) { entries.append(value) }
}

/// One-shot async signal — lets a test hold an operation open so a second one
/// genuinely overlaps it.
private actor AsyncSignal {
    private var isSignalled = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
