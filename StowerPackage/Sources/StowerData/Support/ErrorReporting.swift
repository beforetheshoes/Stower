import Foundation
import IssueReporting
import OSLog

/// Runs `operation`, reporting an unexpected error instead of discarding it.
///
/// This replaces `try?` around database and file work in effects. `try?`
/// made a failed write indistinguishable from a successful one; this keeps
/// the same "carry on" behaviour while making the failure visible — a
/// runtime warning in development, a failure in tests.
///
/// Two errors are expected and stay quiet: cancellation, and the database
/// refusing work because the app is being suspended. Both mean "run again
/// later", and the callers already arrange that.
@discardableResult
public func reportingErrors<Value>(
    isolation: isolated (any Actor)? = #isolation,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    _ operation: () async throws -> sending Value
) async -> Value? {
    do {
        return try await operation()
    } catch is CancellationError {
        return nil
    } catch where error.isDatabaseSuspension {
        return nil
    } catch {
        reportIssue(error, fileID: fileID, filePath: filePath, line: line, column: column)
        return nil
    }
}

extension Logger {
    /// The one place the logging subsystem is spelled.
    public static let stowerSubsystem = "com.ryanleewilliams.stower"

    /// A logger in Stower's subsystem.
    public static func stower(_ category: String) -> Logger {
        Logger(subsystem: stowerSubsystem, category: category)
    }
}
