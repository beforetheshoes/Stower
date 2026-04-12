import Foundation

public struct CloudSyncStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case available
        case unavailable(String)
        case error(String)
        case needsLocalReset(String)
    }

    public var state: State
    public var lastSyncAttempt: Date?
    public var lastSyncSuccess: Date?

    public init(
        state: State = .starting,
        lastSyncAttempt: Date? = nil,
        lastSyncSuccess: Date? = nil
    ) {
        self.state = state
        self.lastSyncAttempt = lastSyncAttempt
        self.lastSyncSuccess = lastSyncSuccess
    }

    public static let starting = Self(state: .starting)
}
