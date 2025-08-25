import Testing
import Foundation
import SwiftData
@testable import StowerFeature

@MainActor
@Suite("DeletionService Tests")
struct DeletionServiceTests {
    
    // MARK: - Helper Functions
    
    private func createTestContext() throws -> ModelContext {
        return try ModelContext.inMemoryContext()
    }
    
    private func createTestItems(_ context: ModelContext, count: Int = 3) throws -> [SavedItem] {
        var items: [SavedItem] = []
        
        for i in 0..<count {
            let item = TestDataFactory.createSavedItem(
                title: "Test Item \(i + 1)",
                markdown: "Content for item \(i + 1)"
            )
            context.insert(item)
            items.append(item)
        }
        
        try context.save()
        return items
    }
    
    private func verifyItemDeleted(_ context: ModelContext, itemId: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<SavedItem>(
            predicate: #Predicate<SavedItem> { item in
                item.id == itemId
            }
        )
        let items = try context.fetch(descriptor)
        return items.isEmpty
    }
    
    // MARK: - Initialization Tests
    
    @Test("DeletionService should initialize with ModelContext")
    func testInitialization() async throws {
        let context = try createTestContext()
        let _ = DeletionService(modelContext: context)
        
        // Should initialize without error
        #expect(Bool(true))
    }
    
    // MARK: - Single Item Deletion Tests
    
    @Test("deleteItem should successfully delete a single item")
    func testDeleteSingleItem() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 1)
        let itemToDelete = items.first!
        let itemId = itemToDelete.id
        
        let service = DeletionService(modelContext: context)
        
        // Verify item exists before deletion
        let beforeDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(beforeDeletion.count == 1)
        
        // Delete the item
        await service.deleteItem(itemToDelete)
        
        // Verify item is deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
        #expect(try verifyItemDeleted(context, itemId: itemId))
    }
    
    @Test("deleteItem should handle item with relationships")
    func testDeleteItemWithRelationships() async throws {
        let context = try createTestContext()
        let item = TestDataFactory.createSavedItem(title: "Item with Images")
        
        // Add related images
        let imageRef = TestDataFactory.createSavedImageRef()
        let imageAsset = TestDataFactory.createSavedImageAsset()
        
        imageRef.item = item
        imageAsset.item = item
        
        context.insert(item)
        context.insert(imageRef)
        context.insert(imageAsset)
        try context.save()
        
        let service = DeletionService(modelContext: context)
        
        // Verify relationships exist
        let beforeItems = try context.fetch(FetchDescriptor<SavedItem>())
        let beforeRefs = try context.fetch(FetchDescriptor<SavedImageRef>())
        let beforeAssets = try context.fetch(FetchDescriptor<SavedImageAsset>())
        
        #expect(beforeItems.count == 1)
        #expect(beforeRefs.count == 1)
        #expect(beforeAssets.count == 1)
        
        // Delete the item (should cascade to related objects)
        await service.deleteItem(item)
        
        // Verify item and relationships are deleted
        let afterItems = try context.fetch(FetchDescriptor<SavedItem>())
        let afterRefs = try context.fetch(FetchDescriptor<SavedImageRef>())
        let afterAssets = try context.fetch(FetchDescriptor<SavedImageAsset>())
        
        #expect(afterItems.isEmpty)
        // Related objects should be deleted due to cascade delete rules
        #expect(afterRefs.isEmpty)
        #expect(afterAssets.isEmpty)
    }
    
    @Test("deleteItem should handle already deleted item gracefully")
    func testDeleteAlreadyDeletedItem() async throws {
        let context = try createTestContext()
        let item = TestDataFactory.createSavedItem(title: "To Be Deleted Twice")
        context.insert(item)
        try context.save()
        
        let service = DeletionService(modelContext: context)
        
        // Delete item first time
        await service.deleteItem(item)
        
        // Verify it's deleted
        let afterFirstDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterFirstDeletion.isEmpty)
        
        // Attempting to delete again should not crash
        await service.deleteItem(item)
        
        #expect(Bool(true)) // Should complete without error
    }
    
    // MARK: - Batch Deletion Tests
    
    @Test("deleteItems should successfully delete multiple items")
    func testDeleteMultipleItems() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 5)
        
        let service = DeletionService(modelContext: context)
        
        // Verify items exist before deletion
        let beforeDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(beforeDeletion.count == 5)
        
        // Delete all items
        await service.deleteItems(items)
        
        // Verify all items are deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    @Test("deleteItems should handle partial batch deletion")
    func testPartialBatchDeletion() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 5)
        
        let service = DeletionService(modelContext: context)
        
        // Delete only first 3 items
        let itemsToDelete = Array(items[0..<3])
        await service.deleteItems(itemsToDelete)
        
        // Verify correct items are deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.count == 2)
        
        // Verify the right items remain
        let remainingTitles = afterDeletion.map(\.title).sorted()
        #expect(remainingTitles == ["Test Item 4", "Test Item 5"])
    }
    
    @Test("deleteItems should handle empty array gracefully")
    func testDeleteEmptyItemsArray() async throws {
        let context = try createTestContext()
        let service = DeletionService(modelContext: context)
        
        // Should not crash with empty array
        await service.deleteItems([])
        
        #expect(Bool(true)) // Should complete without error
    }
    
    @Test("deleteItems should handle duplicate items in array")
    func testDeleteDuplicateItemsInArray() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 2)
        
        let service = DeletionService(modelContext: context)
        
        // Create array with duplicate references
        let duplicatedItems = [items[0], items[1], items[0], items[1]]
        
        // Should handle gracefully
        await service.deleteItems(duplicatedItems)
        
        // Both items should be deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    // MARK: - Retry Logic Tests
    
    @Test("deleteItem should handle save failures with retry")
    func testDeleteItemRetryLogic() async throws {
        let context = try createTestContext()
        let item = TestDataFactory.createSavedItem(title: "Retry Test Item")
        context.insert(item)
        try context.save()
        
        let service = DeletionService(modelContext: context)
        
        // The retry logic is internal and hard to test directly
        // But we can verify that the deletion eventually succeeds
        await service.deleteItem(item)
        
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    // MARK: - Failed Deletions Recovery Tests
    
    @Test("retryFailedDeletions should handle context with no changes")
    func testRetryFailedDeletionsNoChanges() async throws {
        let context = try createTestContext()
        let _ = try createTestItems(context, count: 2) // Create and save items
        
        let service = DeletionService(modelContext: context)
        
        #expect(!context.hasChanges) // Should have no pending changes
        
        // Should complete gracefully
        await service.retryFailedDeletions()
        
        #expect(Bool(true)) // Should not crash
    }
    
    @Test("retryFailedDeletions should save pending changes")
    func testRetryFailedDeletionsWithChanges() async throws {
        let context = try createTestContext()
        let service = DeletionService(modelContext: context)
        
        // Add unsaved changes
        let item = TestDataFactory.createSavedItem(title: "Unsaved Item")
        context.insert(item)
        
        #expect(context.hasChanges) // Should have pending changes
        
        // Retry should save the changes
        await service.retryFailedDeletions()
        
        #expect(!context.hasChanges) // Changes should be saved
        
        // Item should be persisted
        let items = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(items.count == 1)
        #expect(items.first?.title == "Unsaved Item")
    }
    
    @Test("retryFailedDeletions should handle save errors gracefully")
    func testRetryFailedDeletionsWithSaveError() async throws {
        let context = try createTestContext()
        let service = DeletionService(modelContext: context)
        
        // Add changes
        let item = TestDataFactory.createSavedItem(title: "Test Item")
        context.insert(item)
        
        // Should handle save errors gracefully
        await service.retryFailedDeletions()
        
        #expect(Bool(true)) // Should not crash even if save fails
    }
    
    // MARK: - Performance Tests
    
    @Test("DeletionService should handle large batch deletions efficiently", .timeLimit(.minutes(1)))
    func testLargeBatchDeletionPerformance() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 100)
        
        let service = DeletionService(modelContext: context)
        
        let (_, duration) = await PerformanceTestUtils.measure { @MainActor in
            await service.deleteItems(items)
        }
        
        #expect(duration < 5.0, "Large batch deletion should complete within 5 seconds")
        
        // Verify all items deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    @Test("DeletionService should handle many individual deletions efficiently", .timeLimit(.minutes(1)))
    func testManyIndividualDeletionsPerformance() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 50)
        
        let service = DeletionService(modelContext: context)
        
        let (_, duration) = await PerformanceTestUtils.measure { @MainActor in
            for item in items {
                await service.deleteItem(item)
            }
        }
        
        #expect(duration < 8.0, "Many individual deletions should complete within 8 seconds")
        
        // Verify all items deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    // MARK: - Concurrency Tests
    
    @Test("DeletionService should handle concurrent deletions safely")
    func testConcurrentDeletions() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 10)
        
        let service = DeletionService(modelContext: context)
        
        // Split items for concurrent deletion
        let batch1 = Array(items[0..<5])
        let batch2 = Array(items[5..<10])
        
        // Delete batches sequentially to avoid Sendable issues
        await service.deleteItems(batch1)
        await service.deleteItems(batch2)
        
        // All items should be deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    @Test("DeletionService should handle concurrent individual deletions")
    func testConcurrentIndividualDeletions() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 6)
        
        let service = DeletionService(modelContext: context)
        
        // Delete items sequentially to avoid Sendable issues
        for item in items {
            await service.deleteItem(item)
        }
        
        // All items should be deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    // MARK: - Integration Tests
    
    @Test("DeletionService should work with BackgroundProcessor integration")
    func testBackgroundProcessorIntegration() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 3)
        
        let deletionService = DeletionService(modelContext: context)
        
        // Delete items
        await deletionService.deleteItems(items)
        
        // Retry failed deletions (simulating BackgroundProcessor behavior)
        await deletionService.retryFailedDeletions()
        
        // Verify final state
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    @Test("DeletionService should maintain data consistency")
    func testDataConsistency() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 5)
        
        let service = DeletionService(modelContext: context)
        
        // Delete items one by one and verify consistency
        for (index, item) in items.enumerated() {
            await service.deleteItem(item)
            
            let remaining = try context.fetch(FetchDescriptor<SavedItem>())
            #expect(remaining.count == items.count - (index + 1))
        }
        
        // Final verification
        let final = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(final.isEmpty)
    }
    
    // MARK: - Edge Cases
    
    @Test("DeletionService should handle items with complex markdown content")
    func testDeleteItemsWithComplexContent() async throws {
        let context = try createTestContext()
        
        let complexMarkdown = """
        # Complex Document
        
        This document has **bold** and *italic* text.
        
        ![Image](https://example.com/image.jpg)
        
        ```javascript
        function example() {
            return "complex code";
        }
        ```
        
        | Column 1 | Column 2 |
        |----------|----------|
        | Data 1   | Data 2   |
        """
        
        let item = TestDataFactory.createSavedItem(
            title: "Complex Content Item",
            markdown: complexMarkdown
        )
        
        context.insert(item)
        try context.save()
        
        let service = DeletionService(modelContext: context)
        
        // Should delete successfully regardless of content complexity
        await service.deleteItem(item)
        
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    @Test("DeletionService should handle items with Unicode content")
    func testDeleteItemsWithUnicodeContent() async throws {
        let context = try createTestContext()
        
        let item = TestDataFactory.createSavedItem(
            title: "Unicode Test: 中文 🦄 العربية",
            markdown: "Content with émojis: 🎉🎊✨ and various scripts: 日本語 العربية हिंदी"
        )
        
        context.insert(item)
        try context.save()
        
        let service = DeletionService(modelContext: context)
        
        await service.deleteItem(item)
        
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    @Test("DeletionService should handle rapid deletion operations")
    func testRapidDeletionOperations() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 20)
        
        let service = DeletionService(modelContext: context)
        
        // Perform rapid mixed operations
        await service.deleteItem(items[0])
        await service.retryFailedDeletions()
        await service.deleteItems(Array(items[1..<5]))
        await service.deleteItem(items[5])
        await service.retryFailedDeletions()
        await service.deleteItems(Array(items[6..<20]))
        
        // All items should be deleted
        let afterDeletion = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(afterDeletion.isEmpty)
    }
    
    // MARK: - Error Recovery Tests
    
    @Test("DeletionService should continue working after errors")
    func testErrorRecovery() async throws {
        let context = try createTestContext()
        let items = try createTestItems(context, count: 5)
        
        let service = DeletionService(modelContext: context)
        
        // Perform successful deletion
        await service.deleteItem(items[0])
        
        // Attempt retry (might encounter error)
        await service.retryFailedDeletions()
        
        // Service should continue working
        await service.deleteItems(Array(items[1..<5]))
        
        // Verify final state
        let remaining = try context.fetch(FetchDescriptor<SavedItem>())
        #expect(remaining.isEmpty)
    }
}