import SwiftUI
import SwiftData
import StowerFeature

@main
struct StowerMacApp: App {
    // Create exactly one ModelContainer per process to avoid duplicate CloudKit handlers
    private let modelContainer: ModelContainer = Persistence.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onAppear {
                    // Process any pending jobs and kick image downloads when app appears
                    Task { @MainActor in
                        processBackgroundJobs()
                        let processor = BackgroundProcessor(modelContext: modelContainer.mainContext)
                        await processor.processPendingImageDownloads()
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
        // Process jobs using the background processor
        let processor = BackgroundProcessor(modelContext: modelContainer.mainContext)
        processor.processPendingJobs()
        
        // Clear them after handing off to the processor
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
