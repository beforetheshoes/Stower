import SwiftUI
import SwiftData

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

public struct ContentView: View {
    @State private var readerSettings = ReaderSettings.loadFromUserDefaults()
    @State private var selectedSection: ContentSection? = .inbox
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showingAddURLDialog = false
    @State private var showingExportDialog = false
    
    public var body: some View {
        #if os(macOS)
        // Always use NavigationSplitView on macOS for native experience
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedSection: $selectedSection)
        } detail: {
            DetailView(selectedSection: selectedSection ?? .inbox)
        }
        .environment(readerSettings)
        .preferredColorScheme(readerSettings.effectiveColorScheme)
        .tint(readerSettings.effectiveAccentColor)
        .navigationSplitViewStyle(.prominentDetail)
        .onReceive(NotificationCenter.default.publisher(for: .showAddURLDialog)) { _ in
            showingAddURLDialog = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showExportDialog)) { _ in
            showingExportDialog = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToInbox)) { _ in
            selectedSection = .inbox
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToLibrary)) { _ in
            selectedSection = .library
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettings)) { _ in
            selectedSection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .importFromClipboard)) { _ in
            importFromClipboard()
        }
        .sheet(isPresented: $showingAddURLDialog) {
            AddURLDialog()
        }
        .sheet(isPresented: $showingExportDialog) {
            // TODO: Implement BulkExportView
            Text("Export functionality coming soon")
                .padding()
        }
        #else
        // iOS adaptive behavior
        GeometryReader { geometry in
            let useTabView = geometry.size.width < 700  // Use TabView for smaller screens
            
            if useTabView {
                TabView {
                    InboxView()
                        .tabItem {
                            Label("Inbox", systemImage: "tray")
                        }
                    
                    LibraryView()
                        .tabItem {
                            Label("Library", systemImage: "books.vertical")
                        }
                    
                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                }
                .environment(readerSettings)
                .preferredColorScheme(readerSettings.effectiveColorScheme)
                .tint(readerSettings.effectiveAccentColor)
            } else {
                // Use NavigationSplitView for larger screens (iPad)
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(selectedSection: $selectedSection)
                } detail: {
                    DetailView(selectedSection: selectedSection ?? .inbox)
                }
                .environment(readerSettings)
                .preferredColorScheme(readerSettings.effectiveColorScheme)
                .tint(readerSettings.effectiveAccentColor)
            }
        }
        .onAppear {
            // Initialize performance services
            initializePerformanceServices()
        }
        #endif
    }
    
    private func initializePerformanceServices() {
        // Performance services have been removed - using native iOS memory management
        print("✅ Using native iOS performance management")
    }
    
    private func importFromClipboard() {
        // Note: SwiftUI doesn't have direct clipboard access yet
        // This functionality should be handled by the system paste action
        // or through a proper paste button that uses .onPasteCommand
        print("Clipboard import should use SwiftUI's .onPasteCommand modifier")
    }
    
    public init() {}
}

struct AddURLDialog: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var urlText = ""
    @State private var isProcessing = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Add URL")
                .font(.title2)
                .fontWeight(.semibold)
            
            TextField("Enter URL or paste from clipboard", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onAppear {
                    // Note: Auto-fill from clipboard should use SwiftUI's .onPasteCommand
                    // or let the user manually paste using system shortcuts
                }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Add") {
                    addURL()
                }
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                .keyboardShortcut(.return)
            }
            
            if isProcessing {
                ProgressView("Processing URL...")
                    .progressViewStyle(CircularProgressViewStyle())
            }
        }
        .padding()
        .compactMacOSDialog()
    }
    
    private func addURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        
        isProcessing = true
        
        Task { @MainActor in
            let item = SavedItem(
                url: url,
                title: url.absoluteString,
                extractedMarkdown: "Loading content..."
            )
            modelContext.insert(item)
            
            // Post notification to process the URL
            NotificationCenter.default.post(
                name: .processURL,
                object: nil,
                userInfo: ["item": item, "url": url]
            )
            
            dismiss()
        }
    }
}

enum ContentSection: String, CaseIterable {
    case inbox = "inbox"
    case library = "library"
    case settings = "settings"
    
    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }
    
    var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .library: return "books.vertical"
        case .settings: return "gear"
        }
    }
}

struct SidebarView: View {
    @Binding var selectedSection: ContentSection?
    
    var body: some View {
        List(ContentSection.allCases, id: \.self, selection: $selectedSection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .navigationTitle("Stower")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    // TODO: Add new item action
                }) {
                    Image(systemName: "plus")
                }
                .help("Add new item")
            }
        }
        #endif
    }
}

struct DetailView: View {
    let selectedSection: ContentSection
    
    var body: some View {
        Group {
            switch selectedSection {
            case .inbox:
                InboxView()
            case .library:
                LibraryView()
            case .settings:
                SettingsView()
            }
        }
        .navigationTitle(selectedSection.title)
        #if os(macOS)
        .navigationSubtitle(subtitleForSection(selectedSection))
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: {
                    // TODO: Refresh action
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                
                Button(action: {
                    // TODO: Search action
                }) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search")
            }
        }
        #endif
    }
    
    private func subtitleForSection(_ section: ContentSection) -> String {
        switch section {
        case .inbox:
            return "Unread articles"
        case .library:
            return "All saved articles"
        case .settings:
            return "App preferences"
        }
    }
}
