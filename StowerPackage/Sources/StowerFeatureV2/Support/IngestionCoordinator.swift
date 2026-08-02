import Dependencies

public struct IngestionCoordinator: Sendable {
    public var run: @Sendable (
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws -> Void

    public init(
        run: @escaping @Sendable (
            _ operation: @escaping @Sendable () async throws -> Void
        ) async throws -> Void
    ) {
        self.run = run
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
            try await operation()
        }
        inFlight = task
        defer {
            if inFlight == task { inFlight = nil }
        }
        try await task.value
    }
}

private enum IngestionCoordinatorKey: DependencyKey {
    static let liveValue: IngestionCoordinator = {
        let gate = IngestionGate()
        return IngestionCoordinator { operation in
            try await gate.run(operation)
        }
    }()

    static let testValue = IngestionCoordinator { operation in
        try await operation()
    }
}

extension DependencyValues {
    public var ingestionCoordinator: IngestionCoordinator {
        get { self[IngestionCoordinatorKey.self] }
        set { self[IngestionCoordinatorKey.self] = newValue }
    }
}
