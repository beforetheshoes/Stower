import SwiftUI
import SwiftData

public struct SettingsView: View {
    @Query private var allItems: [SavedItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(ReaderSettings.self) private var readerSettings
    @State private var showingClearDataAlert = false
    @State private var showingReaderSettings = false
    
    private var totalItems: Int {
        allItems.count
    }
    
    private var totalImages: Int {
        allItems.reduce(0) { $0 + $1.images.count }
    }
    
    private var storageSize: String {
        let totalBytes = allItems.reduce(0) { total, item in
            total + item.images.values.reduce(0) { $0 + $1.count }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }
    
    public var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Button {
                        showingReaderSettings = true
                    } label: {
                        HStack {
                            Label("Reader Settings", systemImage: "textformat")
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(readerSettings.effectiveAccentColor)
                                    .frame(width: 12, height: 12)
                                Text(readerSettings.selectedPreset.rawValue)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                
                Section("Statistics") {
                    HStack {
                        Label("Total Articles", systemImage: "doc.text")
                        Spacer()
                        Text("\(totalItems)")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Label("Total Images", systemImage: "photo")
                        Spacer()
                        Text("\(totalImages)")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Label("Storage Used", systemImage: "internaldrive")
                        Spacer()
                        Text(storageSize)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Data Management") {
                    Button(role: .destructive) {
                        showingClearDataAlert = true
                    } label: {
                        Label("Clear All Data", systemImage: "trash")
                    }
                    .disabled(totalItems == 0)
                }
                
                Section("Export") {
                    NavigationLink {
                        BulkExportView()
                    } label: {
                        Label("Export All Articles", systemImage: "square.and.arrow.up")
                    }
                    .disabled(totalItems == 0)
                }
                
                Section("About") {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    
                    Link(destination: URL(string: "https://github.com")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                
                Section("Sync Status") {
                    SyncStatusView()
                }
            }
            .navigationTitle("Settings")
            .alert("Clear All Data", isPresented: $showingClearDataAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    clearAllData()
                }
            } message: {
                Text("This will permanently delete all saved articles and images. This action cannot be undone.")
            }
            .sheet(isPresented: $showingReaderSettings) {
                ReaderSettingsSheet()
                    .environment(readerSettings)
            }
        }
    }
    
    private func clearAllData() {
        for item in allItems {
            modelContext.delete(item)
        }
    }
    
    public init() {}
}

private struct SyncStatusView: View {
    @State private var syncStatus: SyncStatus = .unknown
    
    enum SyncStatus {
        case syncing
        case upToDate
        case error
        case unknown
    }
    
    var body: some View {
        HStack {
            Label("CloudKit Sync", systemImage: "icloud")
            
            Spacer()
            
            switch syncStatus {
            case .syncing:
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Syncing...")
                }
                .foregroundStyle(.secondary)
                
            case .upToDate:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Up to Date")
                }
                .foregroundStyle(.secondary)
                
            case .error:
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Sync Error")
                }
                .foregroundStyle(.secondary)
                
            case .unknown:
                Text("Unknown")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            checkSyncStatus()
        }
    }
    
    private func checkSyncStatus() {
        syncStatus = .upToDate
    }
}

private struct BulkExportView: View {
    @Query private var allItems: [SavedItem]
    @State private var exportFormat: ExportFormat = .markdown
    @State private var includeImages = true
    
    enum ExportFormat: String, CaseIterable {
        case markdown = "Markdown"
        case json = "JSON"
    }
    
    var body: some View {
        List {
            Section("Export Options") {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                
                Toggle("Include Images", isOn: $includeImages)
            }
            
            Section("Export Content") {
                HStack {
                    Text("Articles to Export")
                    Spacer()
                    Text("\(allItems.count)")
                        .foregroundStyle(.secondary)
                }
                
                if includeImages {
                    HStack {
                        Text("Images to Include")
                        Spacer()
                        Text("\(allItems.reduce(0) { $0 + $1.images.count })")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("Actions") {
                Button("Export All Articles") {
                    // TODO: Implement native SwiftUI sharing
                    // Should use ShareLink or .sheet with UIActivityViewController
                    print("Export functionality - use ShareLink instead of clipboard")
                }
                .disabled(allItems.isEmpty)
            }
        }
        .navigationTitle("Bulk Export")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
    
    private func generateExportContent() -> String {
        switch exportFormat {
        case .markdown:
            return allItems.map { item in
                var content = "# \(item.title)\n\n"
                
                if let url = item.url {
                    content += "**Source:** \(url.absoluteString)\n\n"
                }
                
                content += "**Added:** \(item.dateAdded.formatted())\n\n"
                
                if !item.tags.isEmpty {
                    content += "**Tags:** \(item.tags.joined(separator: ", "))\n\n"
                }
                
                content += "---\n\n"
                content += item.extractedMarkdown
                content += "\n\n"
                
                return content
            }.joined(separator: "\n---\n\n")
            
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            
            let exportData = allItems.map { item in
                ExportItem(
                    id: item.id,
                    url: item.url?.absoluteString,
                    title: item.title,
                    content: item.extractedMarkdown,
                    dateAdded: item.dateAdded,
                    dateModified: item.dateModified,
                    tags: item.tags
                )
            }
            
            if let data = try? encoder.encode(exportData),
               let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            }
            return "[]"
        }
    }
}

private struct ExportItem: Codable {
    let id: UUID
    let url: String?
    let title: String
    let content: String
    let dateAdded: Date
    let dateModified: Date
    let tags: [String]
}