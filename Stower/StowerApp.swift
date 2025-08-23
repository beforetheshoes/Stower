import SwiftUI
import SwiftData
import StowerFeature

@main
struct StowerApp: App {
    // Create exactly one ModelContainer per process to avoid duplicate CloudKit handlers
    private let modelContainer: ModelContainer = Persistence.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onAppear {
                    // Process pending jobs and kick image downloads when app appears
                    Task { @MainActor in
                        // Check CloudKit sync health first
                        let syncMonitor = CloudKitSyncMonitor(modelContext: modelContainer.mainContext)
                        syncMonitor.checkSyncHealth()
                        
                        processBackgroundJobs()
                        let processor = BackgroundProcessor(modelContext: modelContainer.mainContext)
                        
                        // Migrate existing items to create SavedImageRef objects
                        processor.migrateExistingImageReferences()
                        
                        await processor.processPendingImageDownloads()
                        
                        // Final sync health check and cleanup
                        syncMonitor.checkForOrphanedImages()
                    }
                }
        }
    }
    
    @MainActor
    private func processBackgroundJobs() {
        // Check for pending jobs from Share Extension
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        
        guard let pendingJobs = defaults.array(forKey: "pendingProcessingJobs") as? [[String: String]],
              !pendingJobs.isEmpty else {
            return
        }
        
        print("Found \(pendingJobs.count) pending background jobs")
        
        // Process jobs using the background processor
        let processor = BackgroundProcessor(modelContext: modelContainer.mainContext)
        processor.processPendingJobs()
        
        // Also process any pending image downloads
        Task {
            await processor.processPendingImageDownloads()
        }
    }
}
