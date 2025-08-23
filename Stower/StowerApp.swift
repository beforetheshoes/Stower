import SwiftUI
import SwiftData
import StowerFeature

@main
struct StowerApp: App {
    private var modelContainer: ModelContainer {
        do {
            let container = try ModelContainer(
                for: SavedItem.self,
                configurations: ModelConfiguration(
                    groupContainer: .identifier("group.com.ryanleewilliams.stower"),
                    cloudKitDatabase: .automatic
                )
            )
            
            // Configure CloudKit sync
            container.mainContext.autosaveEnabled = true
            
            #if DEBUG
            // Add sample data in debug mode if needed
            let descriptor = FetchDescriptor<SavedItem>()
            let existingItems = try container.mainContext.fetch(descriptor)
            
            if existingItems.isEmpty {
                let sampleItem = SavedItem.preview
                container.mainContext.insert(sampleItem)
            }
            #endif
            
            return container
        } catch {
            print("Failed to configure model container: \(error)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onAppear {
                    // Process any pending jobs from Share Extension when app appears
                    Task { @MainActor in
                        processBackgroundJobs()
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
        // For now, just clear them - actual processing would happen with proper container setup
        defaults.removeObject(forKey: "pendingProcessingJobs")
    }
}
