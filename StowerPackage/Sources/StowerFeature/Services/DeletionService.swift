import Foundation
import SwiftData

/// Service for handling item deletions with CloudKit sync reliability
@MainActor
public class DeletionService {
    private let modelContext: ModelContext
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    /// Deletes a single item with retry logic
    public func deleteItem(_ item: SavedItem) async {
        print("🗑️ DeletionService: Starting deletion of '\(item.title)' (ID: \(item.id))")
        
        // Store item info for logging
        let itemTitle = item.title
        let itemId = item.id
        
        // Perform deletion
        modelContext.delete(item)
        
        // Attempt to save with retries
        await saveWithRetry(itemTitle: itemTitle, itemId: itemId)
    }
    
    /// Deletes multiple items with retry logic
    public func deleteItems(_ items: [SavedItem]) async {
        print("🗑️ DeletionService: Starting batch deletion of \(items.count) items")
        
        // Perform deletions
        for item in items {
            modelContext.delete(item)
        }
        
        // Attempt to save with retries
        await saveWithRetry(itemTitle: "batch of \(items.count) items", itemId: nil)
    }
    
    private func saveWithRetry(itemTitle: String, itemId: UUID?) async {
        let maxRetries = 3
        var attempt = 0
        
        while attempt < maxRetries {
            attempt += 1
            
            do {
                try modelContext.save()
                print("✅ DeletionService: Successfully saved deletion of '\(itemTitle)' to CloudKit (attempt \(attempt))")
                return
            } catch {
                print("❌ DeletionService: Attempt \(attempt)/\(maxRetries) failed to save deletion of '\(itemTitle)': \(error)")
                
                if attempt < maxRetries {
                    // Wait with exponential backoff before retry
                    let delaySeconds = pow(2.0, Double(attempt - 1)) // 1s, 2s, 4s
                    print("⏳ DeletionService: Waiting \(delaySeconds)s before retry...")
                    try? await Task.sleep(for: .seconds(delaySeconds))
                } else {
                    print("💀 DeletionService: All attempts failed for '\(itemTitle)'. Deletion may not sync to other devices.")
                    // TODO: Could implement a failed deletion queue here
                }
            }
        }
    }
    
    /// Check if there are any failed deletions that need retry
    public func retryFailedDeletions() async {
        // This could check a failed deletions queue if we implement one
        // For now, just ensure any pending context changes are saved
        
        if modelContext.hasChanges {
            print("🔄 DeletionService: Found pending changes, attempting to save...")
            do {
                try modelContext.save()
                print("✅ DeletionService: Successfully saved pending changes")
            } catch {
                print("❌ DeletionService: Failed to save pending changes: \(error)")
            }
        }
    }
}