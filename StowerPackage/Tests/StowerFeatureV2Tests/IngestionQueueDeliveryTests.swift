import ComposableArchitecture
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

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerCancelsTheDrainItIsWaitingOn() async throws {
        // Effects are cancelled as the app enters the background. The gate
        // runs each drain in its own task, and used to leave that task
        // running — fetching and writing — after its caller was cancelled.
        let started = AsyncSignal()
        let coordinator = withDependencies {
            $0.context = .live
        } operation: {
            currentIngestionCoordinator()
        }

        let caller = Task {
            try await coordinator.run {
                await started.signal()
                try await Task.never()
            }
        }
        await started.wait()
        caller.cancel()

        await #expect(throws: CancellationError.self) {
            try await caller.value
        }
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func importInterruptedByBackgroundingRunsAgainOnReturn() async throws {
        // Leaving the app mid-capture used to strand the job in `processing`
        // for ten minutes and charge it one of its three attempts.
        let url = try #require(URL(string: "https://example.com/interrupted"))
        let job = IngestionJob(kind: .url, payload: url.absoluteString)
        let queue = LockIsolated([job])
        let released = LockIsolated<[Set<UUID>]>([])
        let failures = LockIsolated(0)
        let completed = LockIsolated(0)
        let saveCalls = LockIsolated(0)
        let captureStarted = AsyncSignal()
        let coordinator = withDependencies {
            $0.context = .live
        } operation: {
            currentIngestionCoordinator()
        }

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.ingestionCoordinator = coordinator
            $0.articleSaveClient.save = { _ in
                let call = saveCalls.withValue { calls -> Int in
                    calls += 1
                    return calls
                }
                if call == 1 {
                    await captureStarted.signal()
                    try await Task.never()
                }
                return ArticleSaveResult(item: SavedItem(title: "Saved", content: "Body"), state: .ready)
            }
            $0.stowerRepository.claimNextIngestionJob = { _ in
                queue.withValue { $0.isEmpty ? nil : $0.removeFirst() }
            }
            $0.stowerRepository.releaseIngestionJobs = { ids in
                released.withValue { $0.append(ids) }
                queue.withValue { $0.append(job) }
            }
            $0.stowerRepository.failIngestionJob = { _, _, _ in failures.withValue { $0 += 1 } }
            $0.stowerRepository.completeIngestionJob = { _, _ in completed.withValue { $0 += 1 } }
            $0.stowerRepository.fetchFailedIngestionJobs = { [] }
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.library(.urlQueued(url)))
        await store.receive(\.ingestion.saveQueued) {
            $0.ingestion.pendingSaveCount = 1
        }
        await captureStarted.wait()

        await store.send(.sceneDidEnterBackground) {
            $0.isSceneInBackground = true
        }
        // The notice survives the trip to the background.
        #expect(store.state.pendingSaveCount == 1)

        await store.send(.sceneDidBecomeActive) {
            $0.isSceneInBackground = false
        }
        await store.receive(\.ingestion.drainFinished) {
            $0.ingestion.pendingSaveCount = 0
        }

        #expect(released.value == [[job.id]])
        #expect(failures.value == 0)
        #expect(saveCalls.value == 2)
        #expect(completed.value == 1)
    }

    // MARK: - Queue

    @Test
    func releasedJobIsClaimableImmediatelyWithoutLosingAnAttempt() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 8000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        }

        let first = try #require(try await repository.claimNextIngestionJob(now))
        #expect(first.attemptCount == 1)
        // Still claimed: nothing else to hand out.
        #expect(try await repository.claimNextIngestionJob(now) == nil)

        try await repository.releaseIngestionJobs([first.id])

        let second = try #require(try await repository.claimNextIngestionJob(now))
        #expect(second.id == first.id)
        #expect(second.attemptCount == 1)
    }

    @Test
    func processedJobsArePrunedOnceOldAndUnfinishedOnesKept() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        let recent = now.addingTimeInterval(-3600)

        try await database.write { db in
            try IngestionJobLocalTable.insert {
                IngestionJobLocalTable(id: UUID(1), payload: "old-done", processedAt: old, status: "completed")
                IngestionJobLocalTable(id: UUID(2), payload: "old-dismissed", processedAt: old, status: "dismissed")
                IngestionJobLocalTable(id: UUID(3), payload: "recent-done", processedAt: recent, status: "completed")
                IngestionJobLocalTable(id: UUID(4), payload: "old-queued", createdAt: old, status: "queued")
                IngestionJobLocalTable(id: UUID(5), payload: "old-failed", createdAt: old, status: "failed")
            }
            .execute(db)
        }

        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        #expect(try await repository.pruneProcessedIngestionJobs(cutoff) == 2)
        #expect(try await repository.pruneProcessedIngestionJobs(cutoff) == 0)

        let survivors = try await database.read { db in
            try IngestionJobLocalTable.order { $0.payload }.select(\.payload).fetchAll(db)
        }
        #expect(survivors == ["old-failed", "old-queued", "recent-done"])
    }

    @Test
    func releasingDoesNotReviveAJobThatAlreadyFinished() async throws {
        let database = try StowerDatabase.makeDatabase()
        let repository = StowerRepository.live(database: database, cloudSyncClient: .noop)
        let now = Date(timeIntervalSince1970: 9000)

        try await withDependencies {
            $0.date.now = now
            $0.uuid = .incrementing
        } operation: {
            try await repository.enqueueIngestionJob(.url, "https://example.com/post")
        }
        let job = try #require(try await repository.claimNextIngestionJob(now))
        try await repository.completeIngestionJob(job.id, now)

        try await repository.releaseIngestionJobs([job.id])

        #expect(try await repository.claimNextIngestionJob(now) == nil)
    }

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
