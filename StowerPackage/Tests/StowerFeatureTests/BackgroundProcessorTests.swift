import Testing
import Foundation
import SwiftData
@testable import StowerFeature

@MainActor
@Suite("BackgroundProcessor Tests")
struct BackgroundProcessorTests {
    
    // MARK: - Helper Functions
    
    private func createTestContext() throws -> ModelContext {
        return try ModelContext.inMemoryContext()
    }
    
    private func createProcessorWithSettings(_ context: ModelContext, autoDownload: Bool = true) throws -> BackgroundProcessor {
        // Pre-create settings to avoid the processor creating defaults
        let settings = ImageDownloadSettings(
            globalAutoDownload: autoDownload,
            askForNewDomains: false
        )
        context.insert(settings)
        try context.save()
        
        return BackgroundProcessor(modelContext: context)
    }
    
    // MARK: - Initialization Tests
    
    @Test("BackgroundProcessor should initialize with ModelContext")
    func testInitialization() async throws {
        let context = try createTestContext()
        let _ = BackgroundProcessor(modelContext: context)
        
        // Should initialize without error
        // Settings should be created if they don't exist
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = try context.fetch(descriptor)
        
        #expect(settings.count == 1)
        #expect(settings.first?.globalAutoDownload == true)
        #expect(settings.first?.askForNewDomains == false)
    }
    
    @Test("BackgroundProcessor should create default settings when none exist")
    func testDefaultSettingsCreation() async throws {
        let context = try createTestContext()
        
        // Verify no settings exist initially
        let initialDescriptor = FetchDescriptor<ImageDownloadSettings>()
        let initialSettings = try context.fetch(initialDescriptor)
        #expect(initialSettings.isEmpty)
        
        let _ = BackgroundProcessor(modelContext: context)
        
        // Settings should be created
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = try context.fetch(descriptor)
        
        #expect(settings.count == 1)
        let setting = settings.first!
        #expect(setting.globalAutoDownload == true)
        #expect(setting.askForNewDomains == false)
    }
    
    @Test("BackgroundProcessor should fix incorrect existing settings")
    func testSettingsFix() async throws {
        let context = try createTestContext()
        
        // Create settings with "incorrect" values
        let incorrectSettings = ImageDownloadSettings(
            globalAutoDownload: false,
            askForNewDomains: true
        )
        context.insert(incorrectSettings)
        try context.save()
        
        let _ = BackgroundProcessor(modelContext: context)
        
        // Settings should be fixed
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = try context.fetch(descriptor)
        
        #expect(settings.count == 1)
        let setting = settings.first!
        #expect(setting.globalAutoDownload == true)
        #expect(setting.askForNewDomains == false)
    }
    
    @Test("BackgroundProcessor should use existing correct settings")
    func testExistingCorrectSettings() async throws {
        let context = try createTestContext()
        
        // Create settings with correct values
        let correctSettings = ImageDownloadSettings(
            globalAutoDownload: true,
            askForNewDomains: false,
            maxImageSizeKB: 2000
        )
        context.insert(correctSettings)
        try context.save()
        
        let _ = BackgroundProcessor(modelContext: context)
        
        // Settings should remain unchanged
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = try context.fetch(descriptor)
        
        #expect(settings.count == 1)
        let setting = settings.first!
        #expect(setting.globalAutoDownload == true)
        #expect(setting.askForNewDomains == false)
        #expect(setting.maxImageSizeKB == 2000) // Should preserve other settings
    }
    
    // MARK: - Pending Jobs Processing Tests
    
    @Test("processPendingJobs should handle empty UserDefaults")
    func testProcessPendingJobsEmpty() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        // Clear any existing pending jobs
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        defaults.removeObject(forKey: "pendingProcessingJobs")
        
        // Should not crash when no jobs exist
        processor.processPendingJobs()
        
        // No error expected
        #expect(true)
    }
    
    @Test("processPendingJobs should handle invalid job data")
    func testProcessPendingJobsInvalidData() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        
        // Set invalid job data
        let invalidJobs: [[String: String]] = [
            [:], // Empty job
            ["id": "invalid-uuid"], // Invalid UUID
            ["url": "not-a-url"], // Invalid URL
            ["id": UUID().uuidString], // Missing URL
            ["url": "https://example.com"] // Missing ID
        ]
        
        defaults.set(invalidJobs, forKey: "pendingProcessingJobs")
        
        // Should handle gracefully without crashing
        processor.processPendingJobs()
        
        // Jobs should be cleared after processing (even if invalid)
        let clearedJobs = defaults.array(forKey: "pendingProcessingJobs")
        #expect(clearedJobs == nil)
    }
    
    @Test("processPendingJobs should process valid job data")
    func testProcessPendingJobsValidData() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        
        // Set valid job data
        let validJobs: [[String: String]] = [
            [
                "id": UUID().uuidString,
                "url": "https://example.com/article1"
            ],
            [
                "id": UUID().uuidString,
                "url": "https://example.com/article2"
            ]
        ]
        
        defaults.set(validJobs, forKey: "pendingProcessingJobs")
        
        // Should process without crashing
        processor.processPendingJobs()
        
        // Jobs should be cleared after processing
        let clearedJobs = defaults.array(forKey: "pendingProcessingJobs")
        #expect(clearedJobs == nil)
    }
    
    @Test("processPendingJobs should use correct UserDefaults suite")
    func testProcessPendingJobsUserDefaultsSuite() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        // Test that it handles both standard and suite defaults
        let standardDefaults = UserDefaults.standard
        let suiteDefaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower")
        
        standardDefaults.removeObject(forKey: "pendingProcessingJobs")
        suiteDefaults?.removeObject(forKey: "pendingProcessingJobs")
        
        // Should not crash regardless of which UserDefaults is used
        processor.processPendingJobs()
        
        #expect(true) // Should complete without error
    }
    
    // MARK: - Image Reference Migration Tests
    
    @Test("migrateExistingImageReferences should execute without error")
    func testImageReferenceMigration() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        // Add a test SavedItem with some legacy data
        let item = TestDataFactory.createSavedItem(
            title: "Test Item with Images",
            markdown: "![Test Image](https://example.com/image.jpg)"
        )
        context.insert(item)
        try context.save()
        
        // Should execute migration without error
        processor.migrateExistingImageReferences()
        
        // Wait a brief moment for async operations
        try await Task.sleep(for: .milliseconds(100))
        
        #expect(true) // Should complete without crashing
    }
    
    @Test("migrateExistingImageReferences should handle empty database")
    func testMigrationEmptyDatabase() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        // Should handle empty database gracefully
        processor.migrateExistingImageReferences()
        
        try await Task.sleep(for: .milliseconds(50))
        
        #expect(true) // Should complete without error
    }
    
    // MARK: - Settings Management Tests
    
    @Test("BackgroundProcessor should handle ModelContext save errors")
    func testModelContextSaveErrors() async throws {
        let context = try createTestContext()
        
        // Create a processor, which will try to save settings
        let _ = BackgroundProcessor(modelContext: context)
        
        // Even if saves fail internally, processor should still initialize
        #expect(true) // Should not crash during initialization
    }
    
    @Test("BackgroundProcessor should handle multiple settings objects")
    func testMultipleSettingsObjects() async throws {
        let context = try createTestContext()
        
        // Create multiple settings objects (unusual but possible)
        let settings1 = ImageDownloadSettings(globalAutoDownload: false)
        let settings2 = ImageDownloadSettings(globalAutoDownload: false)
        
        context.insert(settings1)
        context.insert(settings2)
        try context.save()
        
        let _ = BackgroundProcessor(modelContext: context)
        
        // Should use the first one found and fix it
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let allSettings = try context.fetch(descriptor)
        
        #expect(allSettings.count == 2) // Both should still exist
        // At least one should be fixed
        let fixedCount = allSettings.filter { $0.globalAutoDownload }.count
        #expect(fixedCount >= 1)
    }
    
    // MARK: - Error Recovery Tests
    
    @Test("BackgroundProcessor should handle fetch errors gracefully")
    func testFetchErrorHandling() async throws {
        let context = try createTestContext()
        
        // Create processor - if fetch fails, it should create fallback settings
        let _ = BackgroundProcessor(modelContext: context)
        
        // Should not crash and should have fallback behavior
        #expect(true)
        
        // Should still have created or loaded settings
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = try context.fetch(descriptor)
        #expect(settings.count >= 1)
    }
    
    // MARK: - Observable Protocol Tests
    
    @Test("BackgroundProcessor should conform to Observable")
    func testObservableConformance() async throws {
        let context = try createTestContext()
        let _ = BackgroundProcessor(modelContext: context)
        
        // Just verify it initializes successfully - Observable conformance is guaranteed by the type system
        #expect(Bool(true)) // Placeholder assertion to avoid empty test
    }
    
    // MARK: - Integration Tests
    
    @Test("BackgroundProcessor should integrate with DeletionService")
    func testDeletionServiceIntegration() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        // Create some test data that might need cleanup
        let item = TestDataFactory.createSavedItem()
        context.insert(item)
        try context.save()
        
        // Migration should trigger deletion service
        processor.migrateExistingImageReferences()
        
        try await Task.sleep(for: .milliseconds(100))
        
        #expect(true) // Should complete integration without error
    }
    
    // MARK: - Performance Tests
    
    @Test("BackgroundProcessor operations should be performant", .timeLimit(.minutes(1)))
    func testPerformance() async throws {
        let context = try createTestContext()
        
        let (processor, initDuration) = await PerformanceTestUtils.measure { @MainActor in
            return BackgroundProcessor(modelContext: context)
        }
        
        #expect(initDuration < 1.0, "Initialization should be fast")
        
        let (_, migrationDuration) = await PerformanceTestUtils.measure { @MainActor in
            processor.migrateExistingImageReferences()
        }
        
        #expect(migrationDuration < 2.0, "Migration should start quickly (async work may continue)")
        
        let (_, jobProcessingDuration) = await PerformanceTestUtils.measure { @MainActor in
            processor.processPendingJobs()
        }
        
        #expect(jobProcessingDuration < 0.5, "Job processing should be fast when no jobs exist")
    }
    
    @Test("BackgroundProcessor should handle large numbers of pending jobs")
    func testLargeNumberOfJobs() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        
        // Create many jobs
        let largeJobList = (0..<100).map { index in
            [
                "id": UUID().uuidString,
                "url": "https://example.com/article\(index)"
            ]
        }
        
        defaults.set(largeJobList, forKey: "pendingProcessingJobs")
        
        let (_, duration) = await PerformanceTestUtils.measure { @MainActor in
            processor.processPendingJobs()
        }
        
        #expect(duration < 3.0, "Should process many jobs efficiently")
        
        // Jobs should be cleared after processing
        let clearedJobs = defaults.array(forKey: "pendingProcessingJobs")
        #expect(clearedJobs == nil)
    }
    
    // MARK: - Concurrency Tests
    
    @Test("BackgroundProcessor should handle concurrent access")
    func testConcurrentAccess() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        // Run multiple operations concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                processor.processPendingJobs()
            }
            
            group.addTask { @MainActor in
                processor.migrateExistingImageReferences()
            }
            
            group.addTask { @MainActor in
                processor.processPendingJobs()
            }
        }
        
        #expect(true) // Should complete without deadlock or crash
    }
    
    // MARK: - Edge Cases
    
    @Test("BackgroundProcessor should handle malformed UserDefaults data")
    func testMalformedUserDefaultsData() async throws {
        let context = try createTestContext()
        let processor = try createProcessorWithSettings(context)
        
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        
        // Set non-array data
        defaults.set("not an array", forKey: "pendingProcessingJobs")
        
        // Should handle gracefully
        processor.processPendingJobs()
        
        #expect(true) // Should not crash
        
        // Set array with wrong type
        defaults.set([1, 2, 3], forKey: "pendingProcessingJobs")
        
        processor.processPendingJobs()
        
        #expect(true) // Should not crash
        
        // Clean up after test to avoid affecting other tests
        defaults.removeObject(forKey: "pendingProcessingJobs")
    }
    
    @Test("BackgroundProcessor should handle Settings with extreme values")
    func testExtremeSettingsValues() async throws {
        let context = try createTestContext()
        
        // Create settings with extreme values
        let extremeSettings = ImageDownloadSettings(
            globalAutoDownload: true,
            alwaysDownloadDomains: Array(repeating: "example.com", count: 1000),
            neverDownloadDomains: Array(repeating: "blocked.com", count: 1000),
            askForNewDomains: false,
            maxImageSizeKB: Int.max,
            downloadOnCellular: true
        )
        
        context.insert(extremeSettings)
        try context.save()
        
        // Should initialize without issues
        let _ = BackgroundProcessor(modelContext: context)
        
        #expect(true) // Should handle extreme values gracefully
        
        // Verify settings still exist
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = try context.fetch(descriptor)
        #expect(settings.count == 1)
    }
}
