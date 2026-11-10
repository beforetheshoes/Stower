import Dependencies
import Foundation

public struct IngestionCoordinator: Sendable {
    public var run: @Sendable (
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws -> Void
    /// Records a claimed job whose import was cut short by the app being
    /// backgrounded or the drain being cancelled. Nothing is wrong with the
    /// job, so the next drain puts it straight back in the queue instead of
    /// leaving it claimed until the stale-claim timeout.
    public var noteInterrupted: @Sendable (UUID) async -> Void
    /// Returns and clears the jobs recorded by `noteInterrupted`.
    public var takeInterrupted: @Sendable () async -> Set<UUID>

    public init(
        run: @escaping @Sendable (
            _ operation: @escaping @Sendable () async throws -> Void
        ) async throws -> Void
    ) {
        let interrupted = InterruptedIngestionJobs()
        self.run = run
        self.noteInterrupted = { await interrupted.insert($0) }
        self.takeInterrupted = { await interrupted.take() }
    }
}

/// Jobs this process claimed and then had to abandon. Kept in memory because
/// the database refuses writes at the moment an import is interrupted by
/// suspension; if the process dies first, the stale-claim timeout in
/// `claimNextIngestionJob` still recovers the job.
private actor InterruptedIngestionJobs {
    private var ids = Set<UUID>()

    func insert(_ id: UUID) {
        ids.insert(id)
    }

    func take() -> Set<UUID> {
        defer { ids.removeAll() }
        return ids
    }
}

/// Serializes ingestion drains so two of them never claim jobs concurrently.
///
/// The previous implementation awaited the in-flight drain and then returned
/// *without running the new operation at all*. That silently dropped imports:
/// a URL shared while an earlier capture was still running (captures can take
/// 30s+ per article) would sit in the queue untouched, because the drain that
/// was already running had passed its last `claimNextIngestionJob` scan before
/// the new job existed. The user saw "Saved to Stower" and then nothing in the
/// library.
///
/// Requests now wait for the in-flight drain and then run, instead of being
/// discarded.
private actor IngestionGate {
    private var inFlight: Task<Void, Error>?

    func run(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let previous = inFlight
        let task = Task {
            // A failed predecessor must not cancel this drain — each drain
            // reports its own outcome.
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        inFlight = task
        defer {
            if inFlight == task { inFlight = nil }
        }
        // The drain runs in its own task so a later request can wait on it,
        // which means the caller's cancellation does not reach it by itself.
        // Without forwarding it, cancelling an effect on the way to the
        // background left the network fetches and database writes running
        // into suspension.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private enum IngestionCoordinatorKey: DependencyKey {
    static let liveValue: IngestionCoordinator = {
        let gate = IngestionGate()
        return IngestionCoordinator { operation in
            try await gate.run(operation)
        }
    }()

    static var testValue: IngestionCoordinator {
        IngestionCoordinator { operation in
            try await operation()
        }
    }
}

extension DependencyValues {
    public var ingestionCoordinator: IngestionCoordinator {
        get { self[IngestionCoordinatorKey.self] }
        set { self[IngestionCoordinatorKey.self] = newValue }
    }
}
