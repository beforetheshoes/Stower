import Foundation
import GRDB

#if canImport(UIKit)
import UIKit
#endif

/// Drives GRDB's database suspension around the app lifecycle.
///
/// The database lives in an App Group container shared with the share
/// extension. iOS terminates a process with `0xDEAD10CC` if it is still
/// holding a lock on a file in a shared container when it gets suspended.
/// Setting `Configuration.observesSuspensionNotifications` is only half the
/// technique — something has to actually post the notifications.
///
/// Suspending on background means an in-flight write fails with
/// `SQLITE_INTERRUPT` or `SQLITE_ABORT` instead of taking the process down.
/// Callers treat those as "try again once we're back", not as real failures —
/// see `DatabaseError.isSuspended`.
///
/// macOS has no equivalent suspension, so this is a no-op there.
public enum DatabaseSuspensionObserver {
    /// Whether this platform suspends processes in a way that triggers
    /// `0xDEAD10CC`.
    ///
    /// iOS and iPadOS do. macOS does not — and suspending there would be
    /// actively harmful: a Mac app in the background is still expected to run
    /// its periodic CloudKit sync, and a suspended database would interrupt
    /// every one of those writes for no benefit.
    public static var isSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Tells the database to stop acquiring locks. Post before the process is
    /// suspended — i.e. as the app enters the background.
    public static func suspend() {
        guard isSupported else { return }
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Lets the database acquire locks again. Post when the app returns to the
    /// foreground, or before any background-mode work that touches the database.
    public static func resume() {
        guard isSupported else { return }
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }
}

extension DatabaseError {
    /// Whether this error is the database refusing to work because it has been
    /// suspended, rather than anything being wrong with the data.
    ///
    /// GRDB surfaces suspension as `SQLITE_INTERRUPT` or `SQLITE_ABORT`. Work
    /// that hits one of these should be left alone to run again after the app
    /// resumes — retrying immediately would just fail the same way, and
    /// recording it as a failure would blame the user's data for the app
    /// being backgrounded.
    public var isSuspended: Bool {
        resultCode == .SQLITE_INTERRUPT || resultCode == .SQLITE_ABORT
    }
}

extension Error {
    /// Whether this error was caused by database suspension, at any depth.
    public var isDatabaseSuspension: Bool {
        (self as? DatabaseError)?.isSuspended ?? false
    }
}
