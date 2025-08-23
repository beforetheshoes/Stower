import SwiftUI
import SwiftData
import StowerFeature

@main
struct StowerMacApp: App {
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
        .defaultSize(width: 1200, height: 800)
        .commands {
            StowerCommands()
        }
        
        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(modelContainer)
        }
        #endif
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

struct StowerCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add URL...") {
                NotificationCenter.default.post(name: .showAddURLDialog, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            
            Divider()
            
            Button("Import from Clipboard") {
                NotificationCenter.default.post(name: .importFromClipboard, object: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        
        CommandGroup(after: .importExport) {
            Button("Export All Articles...") {
                NotificationCenter.default.post(name: .showExportDialog, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        
        CommandGroup(after: .sidebar) {
            Button("Show Inbox") {
                NotificationCenter.default.post(name: .navigateToInbox, object: nil)
            }
            .keyboardShortcut("1", modifiers: .command)
            
            Button("Show Library") {
                NotificationCenter.default.post(name: .navigateToLibrary, object: nil)
            }
            .keyboardShortcut("2", modifiers: .command)
            
            Button("Show Settings") {
                NotificationCenter.default.post(name: .navigateToSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        
        CommandGroup(replacing: .help) {
            Button("Stower Help") {
                if let url = URL(string: "https://github.com") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

// Notification extensions for menu commands
extension Notification.Name {
    static let showAddURLDialog = Notification.Name("showAddURLDialog")
    static let importFromClipboard = Notification.Name("importFromClipboard")
    static let showExportDialog = Notification.Name("showExportDialog")
    static let navigateToInbox = Notification.Name("navigateToInbox")
    static let navigateToLibrary = Notification.Name("navigateToLibrary")
    static let navigateToSettings = Notification.Name("navigateToSettings")
    static let processURL = Notification.Name("processURL")
}
