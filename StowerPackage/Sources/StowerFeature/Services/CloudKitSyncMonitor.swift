import Foundation
import SwiftData
import CloudKit

/// Monitor for CloudKit sync status and help debug sync issues
@MainActor
public class CloudKitSyncMonitor {
    private let modelContext: ModelContext
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    /// Check for potential sync issues and log diagnostic information
    public func checkSyncHealth() {
        print("🔍 CloudKitSyncMonitor: Checking sync health...")
        
        // Check if context has unsaved changes
        if modelContext.hasChanges {
            print("⚠️ CloudKitSyncMonitor: Model context has unsaved changes")
            
            // Try to save pending changes
            do {
                try modelContext.save()
                print("✅ CloudKitSyncMonitor: Successfully saved pending changes")
            } catch {
                print("❌ CloudKitSyncMonitor: Failed to save pending changes: \(error)")
            }
        } else {
            print("✅ CloudKitSyncMonitor: No pending changes in model context")
        }
        
        // Log database statistics
        logDatabaseStats()
    }
    
    private func logDatabaseStats() {
        do {
            // Count SavedItems
            let itemsDescriptor = FetchDescriptor<SavedItem>()
            let itemsCount = try modelContext.fetch(itemsDescriptor).count
            print("📊 CloudKitSyncMonitor: \(itemsCount) SavedItems in database")
            
            // Count SavedImageRefs
            let refsDescriptor = FetchDescriptor<SavedImageRef>()
            let refsCount = try modelContext.fetch(refsDescriptor).count
            print("📊 CloudKitSyncMonitor: \(refsCount) SavedImageRefs in database")
            
            // Count SavedImageAssets
            let assetsDescriptor = FetchDescriptor<SavedImageAsset>()
            let assetsCount = try modelContext.fetch(assetsDescriptor).count
            print("📊 CloudKitSyncMonitor: \(assetsCount) SavedImageAssets in database")
            
            // Count ImageDownloadSettings
            let settingsDescriptor = FetchDescriptor<ImageDownloadSettings>()
            let settingsCount = try modelContext.fetch(settingsDescriptor).count
            print("📊 CloudKitSyncMonitor: \(settingsCount) ImageDownloadSettings in database")
            
        } catch {
            print("❌ CloudKitSyncMonitor: Failed to fetch database stats: \(error)")
        }
    }
    
    /// Force a save operation to help with sync
    public func forceSyncSave() {
        print("🔄 CloudKitSyncMonitor: Forcing sync save...")
        
        do {
            try modelContext.save()
            print("✅ CloudKitSyncMonitor: Successfully performed force save")
        } catch {
            print("❌ CloudKitSyncMonitor: Force save failed: \(error)")
        }
    }
    
    /// Check for orphaned image references (debugging utility)
    public func checkForOrphanedImages() {
        print("🔍 CloudKitSyncMonitor: Checking for orphaned images...")
        
        do {
            // Find SavedImageRefs without parent items
            let refsDescriptor = FetchDescriptor<SavedImageRef>()
            let allRefs = try modelContext.fetch(refsDescriptor)
            let orphanedRefs = allRefs.filter { $0.item == nil }
            
            if !orphanedRefs.isEmpty {
                print("⚠️ CloudKitSyncMonitor: Found \(orphanedRefs.count) orphaned SavedImageRefs")
                for orphan in orphanedRefs.prefix(5) { // Log first 5
                    print("🗑️ Orphaned SavedImageRef: \(orphan.id)")
                }
            } else {
                print("✅ CloudKitSyncMonitor: No orphaned SavedImageRefs found")
            }
            
            // Find SavedImageAssets without parent items
            let assetsDescriptor = FetchDescriptor<SavedImageAsset>()
            let allAssets = try modelContext.fetch(assetsDescriptor)
            let orphanedAssets = allAssets.filter { $0.item == nil }
            
            if !orphanedAssets.isEmpty {
                print("⚠️ CloudKitSyncMonitor: Found \(orphanedAssets.count) orphaned SavedImageAssets")
                for orphan in orphanedAssets.prefix(5) { // Log first 5
                    print("🗑️ Orphaned SavedImageAsset: \(orphan.id)")
                }
            } else {
                print("✅ CloudKitSyncMonitor: No orphaned SavedImageAssets found")
            }
            
        } catch {
            print("❌ CloudKitSyncMonitor: Failed to check for orphaned images: \(error)")
        }
    }
}