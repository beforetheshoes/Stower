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

private actor IngestionGate {
    private var inFlight: Task<Void, Error>?

    func run(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }

        let task = Task {
            try await operation()
        }
        inFlight = task
        defer { inFlight = nil }
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
