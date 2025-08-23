import SwiftUI
import SwiftData

struct ImageDownloadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var settings: ImageDownloadSettings?
    @State private var domainStats: [DomainImageStats] = []
    @State private var showingDomainDetail: String?
    
    var body: some View {
        NavigationStack {
            Form {
                if let settings = settings {
                    Section("Global Settings") {
                        Toggle("Auto-download images", isOn: Binding(
                            get: { settings.globalAutoDownload },
                            set: { newValue in
                                settings.globalAutoDownload = newValue
                                saveSettings()
                            }
                        ))
                        
                        Toggle("Ask before downloading from new sites", isOn: Binding(
                            get: { settings.askForNewDomains },
                            set: { newValue in
                                settings.askForNewDomains = newValue
                                saveSettings()
                            }
                        ))
                        
                        Toggle("Download on cellular", isOn: Binding(
                            get: { settings.downloadOnCellular },
                            set: { newValue in
                                settings.downloadOnCellular = newValue
                                saveSettings()
                            }
                        ))
                        
                        HStack {
                            Text("Max image size")
                            Spacer()
                            Menu("\(settings.maxImageSizeKB / 1024)MB") {
                                ForEach([1, 2, 5, 10, 20], id: \.self) { mb in
                                    Button("\(mb)MB") {
                                        settings.maxImageSizeKB = mb * 1024
                                        saveSettings()
                                    }
                                }
                            }
                        }
                    }
                    
                    Section("Always Download") {
                        if settings.alwaysDownloadDomains.isEmpty {
                            Text("No sites configured")
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            ForEach(settings.alwaysDownloadDomains, id: \.self) { domain in
                                domainRow(domain: domain, preference: .always)
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    let domain = settings.alwaysDownloadDomains[index]
                                    settings.removeDomain(domain)
                                }
                                saveSettings()
                            }
                        }
                    }
                    
                    Section("Never Download") {
                        if settings.neverDownloadDomains.isEmpty {
                            Text("No sites configured")
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            ForEach(settings.neverDownloadDomains, id: \.self) { domain in
                                domainRow(domain: domain, preference: .never)
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    let domain = settings.neverDownloadDomains[index]
                                    settings.removeDomain(domain)
                                }
                                saveSettings()
                            }
                        }
                    }
                    
                    Section("Storage by Domain") {
                        if domainStats.isEmpty {
                            Text("No images cached yet")
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            ForEach(domainStats, id: \.domain) { stats in
                                Button {
                                    showingDomainDetail = stats.domain
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(stats.domain)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Text(stats.formattedSize)
                                                .foregroundStyle(.secondary)
                                                .font(.caption)
                                        }
                                        
                                        HStack {
                                            Text("\\(stats.imageCount) images")
                                                .foregroundStyle(.tertiary)
                                                .font(.caption2)
                                            
                                            Spacer()
                                            
                                            let preference = settings.getDomainPreference(stats.domain)
                                            Label(preference.displayName, systemImage: preference.systemImage)
                                                .foregroundStyle(Color(preference.color))
                                                .font(.caption2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    Section("Actions") {
                        Button("Clear All Domain Preferences") {
                            settings.clearAllDomainPreferences()
                            saveSettings()
                        }
                        .disabled(!settings.domainStats.hasPreferences)
                        
                        Button("Download All Pending Images", role: .none) {
                            Task {
                                await downloadPendingImages()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Image Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
#else
            .toolbar { Button("Done") { dismiss() } }
#endif
            .sheet(isPresented: Binding(
                get: { showingDomainDetail != nil },
                set: { if !$0 { showingDomainDetail = nil } }
            )) {
                if let domain = showingDomainDetail {
                    DomainDetailView(domain: domain)
                }
            }
        }
        .task {
            await loadSettings()
            await loadDomainStats()
        }
    }
    
    @ViewBuilder
    private func domainRow(domain: String, preference: DomainImagePreference) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(domain)
                
                if domainStats.first(where: { $0.domain == domain }) != nil {
                    Text("\\(stats.imageCount) images • \\(stats.formattedSize)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: preference.systemImage)
                .foregroundStyle(Color(preference.color))
        }
    }
    
    @MainActor
    private func loadSettings() async {
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        do {
            let settingsArray = try modelContext.fetch(descriptor)
            if let firstSetting = settingsArray.first {
                settings = firstSetting
            } else {
                let defaultSettings = ImageDownloadSettings()
                modelContext.insert(defaultSettings)
                settings = defaultSettings
                try? modelContext.save()
            }
        } catch {
            print("❌ ImageDownloadSettingsView: Error loading settings: \\(error)")
        }
    }
    
    private func loadDomainStats() async {
        let imageCache = ImageCacheService.shared
        domainStats = imageCache.getAllDomainStats()
    }
    
    private func saveSettings() {
        do {
            try modelContext.save()
        } catch {
            print("❌ ImageDownloadSettingsView: Error saving settings: \\(error)")
        }
    }
    
    private func downloadPendingImages() async {
        // Create a BackgroundProcessor to handle downloads
        let processor = BackgroundProcessor(modelContext: modelContext)
        await processor.processPendingImageDownloads()
        
        // Reload stats after downloads complete
        await loadDomainStats()
    }
}

// MARK: - Domain Detail View

struct DomainDetailView: View {
    let domain: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var settings: ImageDownloadSettings?
    @State private var domainStats: DomainImageStats?
    
    var body: some View {
        NavigationStack {
            Form {
                if let stats = domainStats {
                    Section("Storage") {
                        LabeledContent("Images", value: "\\(stats.imageCount)")
                        LabeledContent("Total Size", value: stats.formattedSize)
                        LabeledContent("Average Size", value: ByteCountFormatter.string(fromByteCount: Int64(stats.averageSize), countStyle: .file))
                    }
                }
                
                if let settings = settings {
                    Section("Download Preference") {
                        Picker("Preference", selection: Binding(
                            get: { settings.getDomainPreference(domain) },
                            set: { newPreference in
                                switch newPreference {
                                case .always:
                                    settings.addToAlwaysDownload(domain)
                                case .never:
                                    settings.addToNeverDownload(domain)
                                case .default:
                                    settings.removeDomain(domain)
                                }
                                saveSettings()
                            }
                        )) {
                            ForEach(DomainImagePreference.allCases, id: \.rawValue) { preference in
                                Label(preference.displayName, systemImage: preference.systemImage)
                                    .tag(preference)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                
                Section("Actions") {
                    Button("Clear Images for this Domain", role: .destructive) {
                        ImageCacheService.shared.clearImages(for: domain)
                        dismiss()
                    }
                    .disabled(domainStats?.imageCount == 0)
                }
            }
            .navigationTitle(domain)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
#else
            .toolbar { Button("Done") { dismiss() } }
#endif
        }
        .task {
            await loadData()
        }
    }
    
    @MainActor
    private func loadData() async {
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        do {
            let settingsArray = try modelContext.fetch(descriptor)
            settings = settingsArray.first
        } catch {
            print("❌ DomainDetailView: Error loading settings: \\(error)")
        }
        
        let imageCache = ImageCacheService.shared
        domainStats = imageCache.getDomainStats(for: domain)
    }
    
    private func saveSettings() {
        do {
            try modelContext.save()
        } catch {
            print("❌ DomainDetailView: Error saving settings: \\(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    ImageDownloadSettingsView()
        .modelContainer(for: [SavedItem.self, ImageDownloadSettings.self, SavedImageRef.self, SavedImageAsset.self])
}
