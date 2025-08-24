import Foundation
@testable import StowerFeature

extension UserDefaults {
    /// Creates an isolated UserDefaults instance for testing
    static func makeIsolated() -> UserDefaults {
        let suiteName = "tests.stower.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Clear any existing data
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        // Also clear the specific key we use
        defaults.removeObject(forKey: "ReaderSettings")
        defaults.synchronize()
        return defaults
    }
}

/// Helper to set and clear the testing override
struct TestDefaultsScope {
    static func use<T>(_ defaults: UserDefaults, in block: () throws -> T) rethrows -> T {
        // Store any previous override to restore it later
        let previousOverride = ReaderSettings.testingDefaultsOverride
        // Set the new override
        ReaderSettings.testingDefaultsOverride = defaults
        defer { 
            // Restore the previous override (or nil)
            ReaderSettings.testingDefaultsOverride = previousOverride 
        }
        return try block()
    }
    
    static func useAsync<T>(_ defaults: UserDefaults, in block: () async throws -> T) async rethrows -> T {
        // Store any previous override to restore it later
        let previousOverride = ReaderSettings.testingDefaultsOverride
        // Set the new override
        ReaderSettings.testingDefaultsOverride = defaults
        defer { 
            // Restore the previous override (or nil)
            ReaderSettings.testingDefaultsOverride = previousOverride 
        }
        return try await block()
    }
}