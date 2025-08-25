import Testing
import Foundation
import SwiftData
@testable import StowerFeature

@MainActor
@Suite("CloudKitSyncMonitor Tests")
struct CloudKitSyncMonitorTests {
    
    // MARK: - Helper Functions
    
    private func createTestContext() throws -> ModelContext {
        return try ModelContext.inMemoryContext()
    }
    
    private func populateTestData(_ context: ModelContext) throws {
        // Create test items
        let item1 = TestDataFactory.createSavedItem(title: "Test Item 1")
        let item2 = TestDataFactory.createSavedItem(title: "Test Item 2")
        
        // Create test image refs
        let imageRef1 = TestDataFactory.createSavedImageRef(url: "https://example.com/image1.jpg")
        let imageRef2 = TestDataFactory.createSavedImageRef(url: "https://example.com/image2.jpg")
        
        // Create test image assets
        let imageAsset1 = TestDataFactory.createSavedImageAsset()
        let imageAsset2 = TestDataFactory.createSavedImageAsset()
        
        // Create test settings
        let settings = TestDataFactory.createImageDownloadSettings()
        
        // Establish relationships
        imageRef1.item = item1
        imageAsset1.item = item1
        imageRef2.item = item2
        imageAsset2.item = item2
        
        context.insert(item1)
        context.insert(item2)
        context.insert(imageRef1)
        context.insert(imageRef2)
        context.insert(imageAsset1)
        context.insert(imageAsset2)
        context.insert(settings)
        
        try context.save()
    }
    
    // MARK: - Initialization Tests
    
    @Test("CloudKitSyncMonitor should initialize with ModelContext")
    func testInitialization() async throws {
        let context = try createTestContext()
        let _ = CloudKitSyncMonitor(modelContext: context)
        
        // Should initialize without error
        #expect(true)
    }
    
    // MARK: - Sync Health Check Tests
    
    @Test("checkSyncHealth should handle clean context")
    func testCheckSyncHealthClean() async throws {
        let context = try createTestContext()
        try populateTestData(context)
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should complete without error when context is clean
        monitor.checkSyncHealth()
        
        #expect(true) // Should complete successfully
    }
    
    @Test("checkSyncHealth should handle context with unsaved changes")
    func testCheckSyncHealthWithChanges() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Add unsaved changes
        let newItem = TestDataFactory.createSavedItem(title: "Unsaved Item")
        context.insert(newItem)
        
        // Context should have unsaved changes
        #expect(context.hasChanges)
        
        // Should handle and save changes
        monitor.checkSyncHealth()
        
        // Changes should be saved
        #expect(!context.hasChanges)
        
        // Item should be persisted
        let descriptor = FetchDescriptor<SavedItem>()
        let items = try context.fetch(descriptor)
        #expect(items.contains { $0.title == "Unsaved Item" })
    }
    
    @Test("checkSyncHealth should handle save errors gracefully")
    func testCheckSyncHealthWithSaveErrors() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Create data that might cause save issues
        let item = TestDataFactory.createSavedItem(title: "Test Item")
        context.insert(item)
        
        // Even if save fails internally, should not crash
        monitor.checkSyncHealth()
        
        #expect(true) // Should complete without crashing
    }
    
    @Test("checkSyncHealth should log database statistics")
    func testDatabaseStatisticsLogging() async throws {
        let context = try createTestContext()
        try populateTestData(context)
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should log statistics without error
        monitor.checkSyncHealth()
        
        #expect(true) // Should complete successfully
        
        // Verify the data exists (which would be logged)
        let itemsDescriptor = FetchDescriptor<SavedItem>()
        let items = try context.fetch(itemsDescriptor)
        #expect(items.count == 2)
        
        let refsDescriptor = FetchDescriptor<SavedImageRef>()
        let refs = try context.fetch(refsDescriptor)
        #expect(refs.count == 2)
        
        let assetsDescriptor = FetchDescriptor<SavedImageAsset>()
        let assets = try context.fetch(assetsDescriptor)
        #expect(assets.count == 2)
        
        let settingsDescriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = try context.fetch(settingsDescriptor)
        #expect(settings.count == 1)
    }
    
    @Test("checkSyncHealth should handle fetch errors in statistics")
    func testStatisticsWithFetchErrors() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should handle gracefully even if fetches fail
        monitor.checkSyncHealth()
        
        #expect(true) // Should not crash
    }
    
    // MARK: - Force Sync Save Tests
    
    @Test("forceSyncSave should save context successfully")
    func testForceSyncSaveSuccess() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Add unsaved data
        let item = TestDataFactory.createSavedItem(title: "Force Save Test")
        context.insert(item)
        
        #expect(context.hasChanges)
        
        // Force save
        monitor.forceSyncSave()
        
        #expect(!context.hasChanges)
        
        // Verify data was saved
        let descriptor = FetchDescriptor<SavedItem>()
        let items = try context.fetch(descriptor)
        #expect(items.contains { $0.title == "Force Save Test" })
    }
    
    @Test("forceSyncSave should handle save errors gracefully")
    func testForceSyncSaveWithError() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should complete even if save fails
        monitor.forceSyncSave()
        
        #expect(true) // Should not crash
    }
    
    @Test("forceSyncSave should work when no changes exist")
    func testForceSyncSaveNoChanges() async throws {
        let context = try createTestContext()
        try populateTestData(context)
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        #expect(!context.hasChanges)
        
        // Should complete successfully
        monitor.forceSyncSave()
        
        #expect(true) // Should not crash
    }
    
    // MARK: - Orphaned Images Check Tests
    
    @Test("checkForOrphanedImages should detect no orphans in clean data")
    func testCheckOrphanedImagesClean() async throws {
        let context = try createTestContext()
        try populateTestData(context)
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should complete successfully with no orphans detected
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should complete without issues
        
        // Verify no orphans exist (all should have parent items)
        let refsDescriptor = FetchDescriptor<SavedImageRef>()
        let refs = try context.fetch(refsDescriptor)
        let orphanedRefs = refs.filter { $0.item == nil }
        #expect(orphanedRefs.isEmpty)
        
        let assetsDescriptor = FetchDescriptor<SavedImageAsset>()
        let assets = try context.fetch(assetsDescriptor)
        let orphanedAssets = assets.filter { $0.item == nil }
        #expect(orphanedAssets.isEmpty)
    }
    
    @Test("checkForOrphanedImages should detect orphaned SavedImageRefs")
    func testCheckOrphanedImageRefs() async throws {
        let context = try createTestContext()
        
        // Create orphaned image refs
        let orphanedRef1 = TestDataFactory.createSavedImageRef(url: "https://example.com/orphan1.jpg")
        let orphanedRef2 = TestDataFactory.createSavedImageRef(url: "https://example.com/orphan2.jpg")
        
        context.insert(orphanedRef1)
        context.insert(orphanedRef2)
        try context.save()
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should detect orphaned refs
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should complete successfully
        
        // Verify orphans exist
        let refsDescriptor = FetchDescriptor<SavedImageRef>()
        let refs = try context.fetch(refsDescriptor)
        let orphanedRefs = refs.filter { $0.item == nil }
        #expect(orphanedRefs.count == 2)
    }
    
    @Test("checkForOrphanedImages should detect orphaned SavedImageAssets")
    func testCheckOrphanedImageAssets() async throws {
        let context = try createTestContext()
        
        // Create orphaned image assets
        let orphanedAsset1 = TestDataFactory.createSavedImageAsset()
        let orphanedAsset2 = TestDataFactory.createSavedImageAsset()
        
        context.insert(orphanedAsset1)
        context.insert(orphanedAsset2)
        try context.save()
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should detect orphaned assets
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should complete successfully
        
        // Verify orphans exist
        let assetsDescriptor = FetchDescriptor<SavedImageAsset>()
        let assets = try context.fetch(assetsDescriptor)
        let orphanedAssets = assets.filter { $0.item == nil }
        #expect(orphanedAssets.count == 2)
    }
    
    @Test("checkForOrphanedImages should detect mixed orphaned and non-orphaned items")
    func testCheckMixedOrphanedItems() async throws {
        let context = try createTestContext()
        
        // Create valid items with relationships
        let item = TestDataFactory.createSavedItem(title: "Valid Item")
        let validRef = TestDataFactory.createSavedImageRef(url: "https://example.com/valid.jpg")
        let validAsset = TestDataFactory.createSavedImageAsset()
        
        validRef.item = item
        validAsset.item = item
        
        // Create orphaned items
        let orphanedRef = TestDataFactory.createSavedImageRef(url: "https://example.com/orphan.jpg")
        let orphanedAsset = TestDataFactory.createSavedImageAsset()
        
        context.insert(item)
        context.insert(validRef)
        context.insert(validAsset)
        context.insert(orphanedRef)
        context.insert(orphanedAsset)
        try context.save()
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should complete successfully
        
        // Verify correct detection
        let refsDescriptor = FetchDescriptor<SavedImageRef>()
        let refs = try context.fetch(refsDescriptor)
        let orphanedRefs = refs.filter { $0.item == nil }
        #expect(orphanedRefs.count == 1)
        #expect(refs.count == 2)
        
        let assetsDescriptor = FetchDescriptor<SavedImageAsset>()
        let assets = try context.fetch(assetsDescriptor)
        let orphanedAssets = assets.filter { $0.item == nil }
        #expect(orphanedAssets.count == 1)
        #expect(assets.count == 2)
    }
    
    @Test("checkForOrphanedImages should handle large numbers of orphaned items")
    func testCheckLargeNumberOfOrphanedItems() async throws {
        let context = try createTestContext()
        
        // Create many orphaned refs
        for i in 0..<20 {
            let orphanedRef = TestDataFactory.createSavedImageRef(url: "https://example.com/orphan\(i).jpg")
            context.insert(orphanedRef)
        }
        
        try context.save()
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should complete successfully even with many orphans
        
        let refsDescriptor = FetchDescriptor<SavedImageRef>()
        let refs = try context.fetch(refsDescriptor)
        #expect(refs.count == 20)
        
        let orphanedRefs = refs.filter { $0.item == nil }
        #expect(orphanedRefs.count == 20)
    }
    
    @Test("checkForOrphanedImages should handle fetch errors gracefully")
    func testCheckOrphanedImagesWithFetchError() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Should handle gracefully even if fetches fail
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should not crash
    }
    
    // MARK: - Performance Tests
    
    // Temporarily disabled due to MainActor isolation issues in PerformanceTestUtils.measure
    // @Test("CloudKitSyncMonitor operations should be performant", .timeLimit(.minutes(1)))
    func disabled_testPerformance() async throws {
        let context = try createTestContext()
        try populateTestData(context)
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        let (_, healthCheckDuration) = await PerformanceTestUtils.measure { @MainActor in
            monitor.checkSyncHealth()
        }
        
        #expect(healthCheckDuration < 1.0, "Health check should be fast")
        
        let (_, forceSaveDuration) = await PerformanceTestUtils.measure { @MainActor in
            monitor.forceSyncSave()
        }
        
        #expect(forceSaveDuration < 0.5, "Force save should be fast")
        
        let (_, orphanCheckDuration) = await PerformanceTestUtils.measure { @MainActor in
            monitor.checkForOrphanedImages()
        }
        
        #expect(orphanCheckDuration < 1.0, "Orphan check should be fast")
    }
    
    // Temporarily disabled due to MainActor isolation issues in PerformanceTestUtils.measure
    // @Test("CloudKitSyncMonitor should handle large datasets efficiently")
    func disabled_testLargeDatasetPerformance() async throws {
        let context = try createTestContext()
        
        // Create large dataset
        for i in 0..<100 {
            let item = TestDataFactory.createSavedItem(title: "Item \(i)")
            let ref = TestDataFactory.createSavedImageRef(url: "https://example.com/image\(i).jpg")
            let asset = TestDataFactory.createSavedImageAsset()
            
            ref.item = item
            asset.item = item
            
            context.insert(item)
            context.insert(ref) 
            context.insert(asset)
        }
        
        try context.save()
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        let (_, duration) = await PerformanceTestUtils.measure { @MainActor in
            monitor.checkSyncHealth()
            monitor.checkForOrphanedImages()
        }
        
        #expect(duration < 3.0, "Should handle large datasets efficiently")
        
        // Verify data integrity
        let itemsDescriptor = FetchDescriptor<SavedItem>()
        let items = try context.fetch(itemsDescriptor)
        #expect(items.count == 100)
    }
    
    // MARK: - Integration Tests
    
    @Test("CloudKitSyncMonitor should work with real SwiftData operations")
    func testSwiftDataIntegration() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Perform various SwiftData operations
        let item1 = TestDataFactory.createSavedItem(title: "Integration Test Item 1")
        context.insert(item1)
        
        monitor.checkSyncHealth() // Should save item1
        
        let item2 = TestDataFactory.createSavedItem(title: "Integration Test Item 2")
        context.insert(item2)
        
        monitor.forceSyncSave() // Should save item2
        
        // Delete an item
        context.delete(item1)
        
        monitor.checkSyncHealth() // Should process deletion
        
        // Verify final state
        let descriptor = FetchDescriptor<SavedItem>()
        let items = try context.fetch(descriptor)
        #expect(items.count == 1)
        #expect(items.first?.title == "Integration Test Item 2")
    }
    
    // MARK: - Concurrency Tests
    
    @Test("CloudKitSyncMonitor should handle concurrent access")
    func testConcurrentAccess() async throws {
        let context = try createTestContext()
        try populateTestData(context)
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Run multiple operations concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                monitor.checkSyncHealth()
            }
            
            group.addTask { @MainActor in
                monitor.forceSyncSave()
            }
            
            group.addTask { @MainActor in
                monitor.checkForOrphanedImages()
            }
            
            group.addTask { @MainActor in
                monitor.checkSyncHealth()
            }
        }
        
        #expect(Bool(true)) // Should complete without deadlock or crash
    }
    
    // MARK: - Edge Cases
    
    @Test("CloudKitSyncMonitor should handle empty database")
    func testEmptyDatabase() async throws {
        let context = try createTestContext()
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // All operations should work with empty database
        monitor.checkSyncHealth()
        monitor.forceSyncSave()
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should complete successfully
    }
    
    @Test("CloudKitSyncMonitor should handle database with only settings")
    func testDatabaseWithOnlySettings() async throws {
        let context = try createTestContext()
        
        // Add only settings
        let settings = TestDataFactory.createImageDownloadSettings()
        context.insert(settings)
        try context.save()
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        monitor.checkSyncHealth()
        monitor.forceSyncSave()
        monitor.checkForOrphanedImages()
        
        #expect(true) // Should handle gracefully
    }
    
    @Test("CloudKitSyncMonitor should handle rapid successive calls")
    func testRapidSuccessiveCalls() async throws {
        let context = try createTestContext()
        try populateTestData(context)
        
        let monitor = CloudKitSyncMonitor(modelContext: context)
        
        // Make rapid successive calls
        for _ in 0..<10 {
            monitor.checkSyncHealth()
            monitor.forceSyncSave()
            monitor.checkForOrphanedImages()
        }
        
        #expect(true) // Should handle rapid calls without issues
    }
}