import Testing
import Foundation
import SwiftData
@testable import StowerFeature

@MainActor
@Suite("ImageDownloadSettings Tests")
struct ImageDownloadSettingsTests {
    
    // MARK: - Initialization Tests
    
    @Test("ImageDownloadSettings should initialize with default values")
    func testDefaultInitialization() async throws {
        let settings = ImageDownloadSettings()
        
        #expect(settings.globalAutoDownload == true)
        #expect(settings.alwaysDownloadDomains == [])
        #expect(settings.neverDownloadDomains == [])
        #expect(settings.askForNewDomains == false)
        #expect(settings.maxImageSizeKB == 5000)
        #expect(settings.downloadOnCellular == false)
        #expect(settings.lastUpdated.timeIntervalSince1970 > 0)
    }
    
    @Test("ImageDownloadSettings should initialize with custom values")
    func testCustomInitialization() async throws {
        let settings = ImageDownloadSettings(
            globalAutoDownload: false,
            alwaysDownloadDomains: ["trusted.com"],
            neverDownloadDomains: ["blocked.com"],
            askForNewDomains: true,
            maxImageSizeKB: 2000,
            downloadOnCellular: true
        )
        
        #expect(settings.globalAutoDownload == false)
        #expect(settings.alwaysDownloadDomains == ["trusted.com"])
        #expect(settings.neverDownloadDomains == ["blocked.com"])
        #expect(settings.askForNewDomains == true)
        #expect(settings.maxImageSizeKB == 2000)
        #expect(settings.downloadOnCellular == true)
    }
    
    // MARK: - Domain Decision Logic Tests
    
    @Test("shouldDownloadImages should handle nil domain")
    func testNilDomainHandling() async throws {
        let settings = ImageDownloadSettings()
        let decision = settings.shouldDownloadImages(for: nil)
        
        TestAssertions.assertImageDownloadDecision(
            decision,
            expectedShouldDownload: false,
            expectedShouldAsk: false
        )
        #expect(decision.reason.contains("No domain provided"))
    }
    
    @Test("shouldDownloadImages should prioritize never download list")
    func testNeverDownloadPriority() async throws {
        let settings = ImageDownloadSettings(
            globalAutoDownload: true,
            alwaysDownloadDomains: ["example.com"],
            neverDownloadDomains: ["example.com"] // Same domain in both lists
        )
        
        let decision = settings.shouldDownloadImages(for: "example.com")
        
        TestAssertions.assertImageDownloadDecision(
            decision,
            expectedShouldDownload: false,
            expectedShouldAsk: false
        )
        #expect(decision.reason.contains("never download list"))
    }
    
    @Test("shouldDownloadImages should respect always download list")
    func testAlwaysDownloadList() async throws {
        let settings = ImageDownloadSettings(
            globalAutoDownload: false,
            alwaysDownloadDomains: ["trusted.com"]
        )
        
        let decision = settings.shouldDownloadImages(for: "trusted.com")
        
        TestAssertions.assertImageDownloadDecision(
            decision,
            expectedShouldDownload: true,
            expectedShouldAsk: false
        )
        #expect(decision.reason.contains("always download list"))
    }
    
    @Test("shouldDownloadImages should respect global auto-download setting")
    func testGlobalAutoDownload() async throws {
        let settings = ImageDownloadSettings(globalAutoDownload: true)
        let decision = settings.shouldDownloadImages(for: "random.com")
        
        TestAssertions.assertImageDownloadDecision(
            decision,
            expectedShouldDownload: true,
            expectedShouldAsk: false
        )
        #expect(decision.reason.contains("Global auto-download is enabled"))
        
        // Test disabled global auto-download
        settings.globalAutoDownload = false
        let decisionDisabled = settings.shouldDownloadImages(for: "random.com")
        
        TestAssertions.assertImageDownloadDecision(
            decisionDisabled,
            expectedShouldDownload: false,
            expectedShouldAsk: false
        )
    }
    
    @Test("shouldDownloadImages should ask for new domains when configured")
    func testAskForNewDomains() async throws {
        let settings = ImageDownloadSettings(
            globalAutoDownload: false,
            askForNewDomains: true
        )
        
        let decision = settings.shouldDownloadImages(for: "newdomain.com")
        
        TestAssertions.assertImageDownloadDecision(
            decision,
            expectedShouldDownload: false,
            expectedShouldAsk: true
        )
        #expect(decision.reason.contains("requires user decision"))
    }
    
    // MARK: - Domain Management Tests
    
    @Test("addToAlwaysDownload should add domain and clean input")
    func testAddToAlwaysDownload() async throws {
        let settings = ImageDownloadSettings()
        let originalDate = settings.lastUpdated
        
        // Wait to ensure detectable time difference
        try await Task.sleep(for: .milliseconds(10))
        
        settings.addToAlwaysDownload("  EXAMPLE.COM  ")
        
        #expect(settings.alwaysDownloadDomains.contains("example.com"))
        #expect(settings.lastUpdated > originalDate)
        
        // Should not add duplicates
        settings.addToAlwaysDownload("example.com")
        #expect(settings.alwaysDownloadDomains.count == 1)
    }
    
    @Test("addToAlwaysDownload should remove from never download list")
    func testAddToAlwaysDownloadRemovesFromNever() async throws {
        let settings = ImageDownloadSettings()
        settings.addToNeverDownload("example.com")
        
        #expect(settings.neverDownloadDomains.contains("example.com"))
        
        settings.addToAlwaysDownload("example.com")
        
        #expect(settings.alwaysDownloadDomains.contains("example.com"))
        #expect(!settings.neverDownloadDomains.contains("example.com"))
    }
    
    @Test("addToNeverDownload should add domain and clean input")
    func testAddToNeverDownload() async throws {
        let settings = ImageDownloadSettings()
        
        settings.addToNeverDownload("  SPAM.COM  ")
        
        #expect(settings.neverDownloadDomains.contains("spam.com"))
        
        // Should not add duplicates
        settings.addToNeverDownload("spam.com")
        #expect(settings.neverDownloadDomains.count == 1)
    }
    
    @Test("addToNeverDownload should remove from always download list")
    func testAddToNeverDownloadRemovesFromAlways() async throws {
        let settings = ImageDownloadSettings()
        settings.addToAlwaysDownload("example.com")
        
        #expect(settings.alwaysDownloadDomains.contains("example.com"))
        
        settings.addToNeverDownload("example.com")
        
        #expect(settings.neverDownloadDomains.contains("example.com"))
        #expect(!settings.alwaysDownloadDomains.contains("example.com"))
    }
    
    @Test("removeDomain should remove from all lists")
    func testRemoveDomain() async throws {
        let settings = ImageDownloadSettings()
        settings.addToAlwaysDownload("example.com")
        settings.addToNeverDownload("test.com")
        
        settings.removeDomain("  EXAMPLE.COM  ")
        
        #expect(!settings.alwaysDownloadDomains.contains("example.com"))
        #expect(settings.neverDownloadDomains.contains("test.com")) // Should not affect other domains
        
        settings.removeDomain("test.com")
        #expect(!settings.neverDownloadDomains.contains("test.com"))
    }
    
    // MARK: - Domain Preference Tests
    
    @Test("getDomainPreference should return correct preferences")
    func testGetDomainPreference() async throws {
        let settings = ImageDownloadSettings()
        settings.addToAlwaysDownload("always.com")
        settings.addToNeverDownload("never.com")
        
        #expect(settings.getDomainPreference("always.com") == .always)
        #expect(settings.getDomainPreference("never.com") == .never)
        #expect(settings.getDomainPreference("unknown.com") == .default)
        #expect(settings.getDomainPreference(nil) == .default)
    }
    
    @Test("clearAllDomainPreferences should clear all lists")
    func testClearAllDomainPreferences() async throws {
        let settings = ImageDownloadSettings()
        settings.addToAlwaysDownload("always.com")
        settings.addToNeverDownload("never.com")
        
        #expect(settings.alwaysDownloadDomains.count == 1)
        #expect(settings.neverDownloadDomains.count == 1)
        
        let originalDate = settings.lastUpdated
        try await Task.sleep(for: .milliseconds(10))
        
        settings.clearAllDomainPreferences()
        
        #expect(settings.alwaysDownloadDomains.isEmpty)
        #expect(settings.neverDownloadDomains.isEmpty)
        #expect(settings.lastUpdated > originalDate)
    }
    
    // MARK: - Statistics Tests
    
    @Test("domainStats should return correct statistics")
    func testDomainStats() async throws {
        let settings = ImageDownloadSettings()
        
        // Initially empty
        let emptyStats = settings.domainStats
        #expect(emptyStats.alwaysCount == 0)
        #expect(emptyStats.neverCount == 0)
        #expect(emptyStats.totalManaged == 0)
        #expect(!emptyStats.hasPreferences)
        
        // Add some domains
        settings.addToAlwaysDownload("always1.com")
        settings.addToAlwaysDownload("always2.com")
        settings.addToNeverDownload("never1.com")
        
        let stats = settings.domainStats
        #expect(stats.alwaysCount == 2)
        #expect(stats.neverCount == 1)
        #expect(stats.totalManaged == 3)
        #expect(stats.hasPreferences)
    }
    
    // MARK: - Snapshot Tests
    
    @Test("snapshot should create correct Sendable snapshot")
    func testSnapshot() async throws {
        let settings = ImageDownloadSettings(
            globalAutoDownload: false,
            alwaysDownloadDomains: ["always.com"],
            neverDownloadDomains: ["never.com"],
            askForNewDomains: true,
            maxImageSizeKB: 2000,
            downloadOnCellular: true
        )
        
        let snapshot = settings.snapshot()
        
        #expect(snapshot.globalAutoDownload == false)
        #expect(snapshot.alwaysDownloadDomains == ["always.com"])
        #expect(snapshot.neverDownloadDomains == ["never.com"])
        #expect(snapshot.askForNewDomains == true)
        #expect(snapshot.maxImageSizeKB == 2000)
        #expect(snapshot.downloadOnCellular == true)
    }
    
    @Test("snapshot shouldDownloadImages should work like original")
    func testSnapshotDecisionLogic() async throws {
        let settings = ImageDownloadSettings(
            globalAutoDownload: true,
            alwaysDownloadDomains: ["always.com"],
            neverDownloadDomains: ["never.com"]
        )
        
        let snapshot = settings.snapshot()
        
        // Test all decision paths
        let neverDecision = snapshot.shouldDownloadImages(for: "never.com")
        TestAssertions.assertImageDownloadDecision(neverDecision, expectedShouldDownload: false)
        
        let alwaysDecision = snapshot.shouldDownloadImages(for: "always.com")
        TestAssertions.assertImageDownloadDecision(alwaysDecision, expectedShouldDownload: true)
        
        let globalDecision = snapshot.shouldDownloadImages(for: "random.com")
        TestAssertions.assertImageDownloadDecision(globalDecision, expectedShouldDownload: true)
        
        let nilDecision = snapshot.shouldDownloadImages(for: nil)
        TestAssertions.assertImageDownloadDecision(nilDecision, expectedShouldDownload: false)
    }
    
    // MARK: - SwiftData Persistence Tests
    
    @Test("ImageDownloadSettings should persist in SwiftData")
    func testSwiftDataPersistence() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let settings = ImageDownloadSettings(
            globalAutoDownload: false,
            alwaysDownloadDomains: ["test.com"],
            maxImageSizeKB: 1000
        )
        
        context.insert(settings)
        try context.save()
        
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let fetchedSettings = try context.fetch(descriptor)
        
        #expect(fetchedSettings.count == 1)
        let retrieved = fetchedSettings.first!
        #expect(retrieved.globalAutoDownload == false)
        #expect(retrieved.alwaysDownloadDomains == ["test.com"])
        #expect(retrieved.maxImageSizeKB == 1000)
    }
    
    // MARK: - Edge Case Tests
    
    @Test("shouldDownloadImages should handle empty strings")
    func testEmptyStringDomain() async throws {
        let settings = ImageDownloadSettings()
        let decision = settings.shouldDownloadImages(for: "")
        
        // Empty string should be treated as a valid domain
        TestAssertions.assertImageDownloadDecision(
            decision,
            expectedShouldDownload: true, // Global auto-download is true by default
            expectedShouldAsk: false
        )
    }
    
    @Test("Domain management should handle whitespace-only domains")
    func testWhitespaceOnlyDomains() async throws {
        let settings = ImageDownloadSettings()
        settings.addToAlwaysDownload("   ")
        
        // Should add empty string after trimming
        #expect(settings.alwaysDownloadDomains.contains(""))
    }
    
    @Test("Multiple domain operations should maintain consistency")
    func testMultipleDomainOperations() async throws {
        let settings = ImageDownloadSettings()
        
        // Add multiple domains
        settings.addToAlwaysDownload("site1.com")
        settings.addToAlwaysDownload("site2.com")
        settings.addToNeverDownload("site3.com")
        
        // Move a domain between lists
        settings.addToNeverDownload("site1.com")
        
        #expect(!settings.alwaysDownloadDomains.contains("site1.com"))
        #expect(settings.neverDownloadDomains.contains("site1.com"))
        #expect(settings.alwaysDownloadDomains.contains("site2.com"))
        #expect(settings.neverDownloadDomains.contains("site3.com"))
        
        // Remove a domain entirely
        settings.removeDomain("site1.com")
        
        #expect(!settings.neverDownloadDomains.contains("site1.com"))
        #expect(settings.getDomainPreference("site1.com") == .default)
    }
}

// MARK: - ImageDownloadDecision and Enum Tests

@Suite("ImageDownloadDecision Tests")
struct ImageDownloadDecisionTests {
    
    @Test("ImageDownloadDecision should have correct boolean properties")
    func testImageDownloadDecisionProperties() async throws {
        let downloadDecision = ImageDownloadDecision.download("Test reason")
        #expect(downloadDecision.shouldDownload == true)
        #expect(downloadDecision.shouldAsk == false)
        #expect(downloadDecision.reason == "Test reason")
        
        let skipDecision = ImageDownloadDecision.skip("Skip reason")
        #expect(skipDecision.shouldDownload == false)
        #expect(skipDecision.shouldAsk == false)
        #expect(skipDecision.reason == "Skip reason")
        
        let askDecision = ImageDownloadDecision.ask("Ask reason")
        #expect(askDecision.shouldDownload == false)
        #expect(askDecision.shouldAsk == true)
        #expect(askDecision.reason == "Ask reason")
    }
}

@Suite("DomainImagePreference Tests")
struct DomainImagePreferenceTests {
    
    @Test("DomainImagePreference should have correct display properties")
    func testDomainImagePreferenceDisplay() async throws {
        #expect(DomainImagePreference.always.displayName == "Always Download")
        #expect(DomainImagePreference.never.displayName == "Never Download")
        #expect(DomainImagePreference.default.displayName == "Use Global Setting")
        
        #expect(DomainImagePreference.always.systemImage == "checkmark.circle.fill")
        #expect(DomainImagePreference.never.systemImage == "xmark.circle.fill")
        #expect(DomainImagePreference.default.systemImage == "circle")
        
        #expect(DomainImagePreference.always.color == "green")
        #expect(DomainImagePreference.never.color == "red")
        #expect(DomainImagePreference.default.color == "secondary")
    }
    
    @Test("DomainImagePreference should be Sendable and CaseIterable")
    func testDomainImagePreferenceProtocols() async throws {
        let allCases = DomainImagePreference.allCases
        #expect(allCases.count == 3)
        #expect(allCases.contains(.always))
        #expect(allCases.contains(.never))
        #expect(allCases.contains(.default))
    }
}

@Suite("DomainStats Tests")
struct DomainStatsTests {
    
    @Test("DomainStats should calculate hasPreferences correctly")
    func testDomainStatsHasPreferences() async throws {
        let emptyStats = DomainStats(alwaysCount: 0, neverCount: 0, totalManaged: 0)
        #expect(!emptyStats.hasPreferences)
        
        let withAlways = DomainStats(alwaysCount: 1, neverCount: 0, totalManaged: 1)
        #expect(withAlways.hasPreferences)
        
        let withNever = DomainStats(alwaysCount: 0, neverCount: 1, totalManaged: 1)
        #expect(withNever.hasPreferences)
        
        let withBoth = DomainStats(alwaysCount: 2, neverCount: 3, totalManaged: 5)
        #expect(withBoth.hasPreferences)
    }
}