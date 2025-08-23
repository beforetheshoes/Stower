import SwiftUI
import SwiftData

public struct StowerImageView: View {
    let uuid: UUID
    let alt: String
    let maxHeight: CGFloat
    
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showingFullScreen = false
    @State private var imageRef: SavedImageRef?
    @State private var imageAsset: SavedImageAsset?
    @State private var showingDownloadOptions = false
    @State private var hasScheduledRetry = false
    
    @Environment(\.modelContext) private var modelContext
    
    public init(uuid: UUID, alt: String = "", maxHeight: CGFloat = 400) {
        self.uuid = uuid
        self.alt = alt
        self.maxHeight = maxHeight
    }
    
    public var body: some View {
        Group {
            if let imageData = imageData {
                #if os(iOS)
                if let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: maxHeight)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                        .onTapGesture {
                            showingFullScreen = true
                        }
                        .accessibilityHint("Tap to view full size")
                } else {
                    fallbackView
                }
                #elseif os(macOS)
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: maxHeight)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                        .onTapGesture {
                            showingFullScreen = true
                        }
                        .accessibilityHint("Tap to view full size")
                } else {
                    fallbackView
                }
                #endif
            } else if isLoading {
                loadingView
            } else {
                fallbackView
            }
        }
        .task {
            await loadImage()
        }
        .sheet(isPresented: $showingDownloadOptions) {
            if let imageRef = imageRef {
                ImageDownloadOptionsSheet(imageRef: imageRef)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let imageData = imageData {
                FullScreenImageViewer(imageData: imageData, alt: alt)
            }
        }
        #elseif os(macOS)
        .sheet(isPresented: $showingFullScreen) {
            if let imageData = imageData {
                MacOSImageViewer(imageData: imageData, alt: alt)
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.gray.opacity(0.1))
            .frame(height: min(maxHeight, 100))
            .overlay {
                ProgressView()
                    .scaleEffect(0.8)
            }
            .accessibilityLabel("Loading image")
    }
    
    @ViewBuilder
    private var fallbackView: some View {
        if let imageRef = imageRef, !hasLocalBytes(for: imageRef) {
            // Downloadable image placeholder
            downloadablePlaceholder
        } else {
            // Standard unavailable placeholder
            standardPlaceholder
        }
    }
    
    @ViewBuilder
    private var downloadablePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.blue.opacity(0.1))
            .frame(height: min(maxHeight, 80))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.blue)
                        .font(.title2)
                    
                    if let domain = imageRef?.domain {
                        Text("Tap to download from \(domain)")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Tap to download")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding(8)
            }
            .onTapGesture {
                Task {
                    print("🖱️ StowerImageView: User tapped to download image \(uuid)")
                    await downloadImage()
                }
            }
            .accessibilityLabel("Downloadable image: \(alt.isEmpty ? "Image" : alt)")
            .accessibilityHint("Tap to download image")
            .contextMenu {
                Button("Download Image") {
                    Task {
                        print("🖱️ StowerImageView: User selected download from context menu for \(uuid)")
                        await downloadImage()
                    }
                }
                
                if let domain = imageRef?.domain {
                    Button("Always download from \(domain)") {
                        showingDownloadOptions = true
                    }
                }
            }
    }
    
    @ViewBuilder
    private var standardPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.gray.opacity(0.15))
            .frame(height: min(maxHeight, 60))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .foregroundColor(.secondary)
                        .font(.title2)
                    
                    // No-op
                }
            }
            .accessibilityLabel(alt.isEmpty ? "Image unavailable" : "\(alt) - unavailable")
    }
    
    @MainActor
    private func loadImage() async {
        guard imageData == nil else { return }
        
        isLoading = true
        loadFailed = false
        
        // First, try to find the image models
        await findImageModels()
        
        // Try different sources in order of preference
        if let data = await tryLoadFromCache() {
            imageData = data
            print("✅ StowerImageView: Loaded from cache \(uuid) (\(data.count) bytes)")
        } else if let data = await tryLoadFromAsset() {
            imageData = data
            print("✅ StowerImageView: Loaded from asset \(uuid) (\(data.count) bytes)")
        } else if let data = await tryLoadFromLegacy() {
            imageData = data
            print("✅ StowerImageView: Loaded from legacy \(uuid) (\(data.count) bytes)")
        } else {
            loadFailed = true
            print("❌ StowerImageView: Failed to load image \(uuid) from any source")
            // If models may still be syncing, schedule a few retries
            await scheduleRetryFindModels()
        }
        
        isLoading = false
    }
    
    @MainActor
    private func findImageModels() async {
        // Try to find SavedImageRef
        let refDescriptor = FetchDescriptor<SavedImageRef>(
            predicate: #Predicate<SavedImageRef> { ref in
                ref.id == uuid
            }
        )
        
        if let refs = try? modelContext.fetch(refDescriptor), let ref = refs.first {
            imageRef = ref
            // Always check if we need to download, don't trust hasLocalFile from other devices
            await maybeAutoDownload()
            return
        }
        
        // Try to find SavedImageAsset
        let assetDescriptor = FetchDescriptor<SavedImageAsset>(
            predicate: #Predicate<SavedImageAsset> { asset in
                asset.id == uuid
            }
        )
        
        if let assets = try? modelContext.fetch(assetDescriptor), let asset = assets.first {
            imageAsset = asset
        }
    }

    @MainActor
    private func scheduleRetryFindModels() async {
        guard !hasScheduledRetry else { return }
        hasScheduledRetry = true
        Task { @MainActor in
            // Extended retry pattern for CloudKit sync delays
            let delays: [UInt64] = [1, 2, 4, 8, 15, 30]
            for (index, d) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: d * 1_000_000_000)
                await findImageModels()
                
                // If we found models, try to auto-download if needed, then load
                if imageRef != nil || imageAsset != nil {
                    print("✅ StowerImageView: Found image models on retry \(index + 1) for \(uuid)")
                    // If we found an imageRef, check if we need to auto-download
                    if imageRef != nil {
                        await maybeAutoDownload()
                    }
                    // Reset loading state and try again
                    imageData = nil
                    isLoading = true
                    loadFailed = false
                    await loadImage()
                    break
                }
                
                print("🔄 StowerImageView: Retry \(index + 1) - still waiting for sync for \(uuid)")
            }
            
            if imageRef == nil && imageAsset == nil {
                print("❌ StowerImageView: All retries exhausted, image models not found for \(uuid)")
                loadFailed = true
                isLoading = false
            }
            
            hasScheduledRetry = false
        }
    }

    @MainActor
    private func maybeAutoDownload() async {
        guard let imageRef = imageRef, let sourceURL = imageRef.sourceURL else { return }
        
        // First check if we actually have the image data locally
        let hasImageInCache = await ImageCacheService.shared.image(for: imageRef.id) != nil
        if hasImageInCache {
            print("✅ StowerImageView: Image \(imageRef.id) found in local cache, no download needed")
            return
        }
        
        print("🔍 StowerImageView: Image \(imageRef.id) not in local cache, checking download settings")
        
        // Fetch settings and decide
        let settingsDescriptor = FetchDescriptor<ImageDownloadSettings>()
        guard let settings = try? modelContext.fetch(settingsDescriptor).first else { 
            print("❌ StowerImageView: No download settings found")
            return 
        }
        
        let domain = imageRef.domain ?? "unknown"
        print("🔍 StowerImageView: Settings check - globalAutoDownload: \(settings.globalAutoDownload), askForNewDomains: \(settings.askForNewDomains)")
        print("🔍 StowerImageView: Domain '\(domain)' - alwaysList: \(settings.alwaysDownloadDomains.contains(domain)), neverList: \(settings.neverDownloadDomains.contains(domain))")
        
        let decision = settings.shouldDownloadImages(for: imageRef.domain)
        if decision.shouldDownload {
            print("✅ StowerImageView: Auto-downloading image \(imageRef.id) from \(sourceURL)")
            await downloadImage()
        } else {
            print("⏭️ StowerImageView: Skipping download for \(sourceURL): \(decision.reason)")
        }
    }

    private func hasLocalBytes(for ref: SavedImageRef) -> Bool {
        // Check if we actually have the image data in our local cache
        // Don't trust hasLocalFile flag as it may be from another device
        
        // First check by UUID - if we have metadata, we likely have the file
        if let _ = ImageCacheService.shared.metadata(for: ref.id) {
            return true
        }
        
        // Also check by source URL in case UUID mapping exists
        if let url = ref.sourceURL {
            let hasSourceURL = ImageCacheService.shared.findUUID(for: url) != nil
            return hasSourceURL
        }
        
        // No local data found
        return false
    }
    
    private func tryLoadFromCache() async -> Data? {
        return await ImageCacheService.shared.image(for: uuid)
    }
    
    private func tryLoadFromAsset() async -> Data? {
        return imageAsset?.imageData
    }
    
    private func tryLoadFromLegacy() async -> Data? {
        // This would require access to the SavedItem, which we don't have here
        // Legacy images should be migrated to the new system
        return nil
    }
    
    @MainActor
    private func downloadImage() async {
        guard let imageRef = imageRef,
              let sourceURL = imageRef.sourceURL else {
            print("❌ StowerImageView: Cannot download - no source URL")
            return
        }
        
        // Get download settings
        let settingsDescriptor = FetchDescriptor<ImageDownloadSettings>()
        guard let settings = try? modelContext.fetch(settingsDescriptor).first else {
            print("❌ StowerImageView: No download settings available")
            return
        }
        
        isLoading = true
        // Mark in-progress before leaving main actor
        imageRef.markDownloadInProgress()
        try? modelContext.save()

        let imageCache = ImageCacheService.shared
        let outcome = await imageCache.downloadImageIfPermitted(
            from: sourceURL,
            settings: settings.snapshot(),
            uuid: imageRef.id
        )

        switch outcome {
        case .downloaded(_, let width, let height), .alreadyCached(_, let width, let height):
            imageRef.width = width
            imageRef.height = height
            imageRef.markDownloadSuccess()
            // Reload the image
            imageData = nil
            await loadImage()
            loadFailed = false
        case .skipped:
            // Keep as pending so user can retry from UI
            imageRef.downloadStatus = .pending
            loadFailed = true
        case .failed:
            imageRef.markDownloadFailure()
            loadFailed = true
        }

        isLoading = false
        try? modelContext.save()
    }
}

// MARK: - Convenience initializers for different size categories

extension StowerImageView {
    public static func small(uuid: UUID, alt: String = "") -> StowerImageView {
        StowerImageView(uuid: uuid, alt: alt, maxHeight: 24)
    }
    
    public static func medium(uuid: UUID, alt: String = "") -> StowerImageView {
        StowerImageView(uuid: uuid, alt: alt, maxHeight: 60)
    }
    
    public static func large(uuid: UUID, alt: String = "") -> StowerImageView {
        StowerImageView(uuid: uuid, alt: alt, maxHeight: 400)
    }
}

// MARK: - Full Screen Image Viewer

private struct FullScreenImageViewer: View {
    let imageData: Data
    let alt: String
    
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea(.all)
                
                GeometryReader { geometry in
                    #if os(iOS)
                    if let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                SimultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            scale = lastScale * value
                                        }
                                        .onEnded { value in
                                            lastScale = scale
                                            // Limit zoom out
                                            if scale < 1.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 1.0
                                                    lastScale = 1.0
                                                    offset = .zero
                                                    lastOffset = .zero
                                                }
                                            }
                                            // Limit zoom in
                                            else if scale > 4.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 4.0
                                                    lastScale = 4.0
                                                }
                                            }
                                        },
                                    DragGesture()
                                        .onChanged { value in
                                            offset = CGSize(
                                                width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height
                                            )
                                        }
                                        .onEnded { value in
                                            lastOffset = offset
                                        }
                                )
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut) {
                                    if scale > 1.0 {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 2.0
                                        lastScale = 2.0
                                    }
                                }
                            }
                    }
                    #elseif os(macOS)
                    if let nsImage = NSImage(data: imageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                SimultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            scale = lastScale * value
                                        }
                                        .onEnded { value in
                                            lastScale = scale
                                            // Limit zoom out
                                            if scale < 1.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 1.0
                                                    lastScale = 1.0
                                                    offset = .zero
                                                    lastOffset = .zero
                                                }
                                            }
                                            // Limit zoom in
                                            else if scale > 4.0 {
                                                withAnimation(.easeInOut) {
                                                    scale = 4.0
                                                    lastScale = 4.0
                                                }
                                            }
                                        },
                                    DragGesture()
                                        .onChanged { value in
                                            offset = CGSize(
                                                width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height
                                            )
                                        }
                                        .onEnded { value in
                                            lastOffset = offset
                                        }
                                )
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut) {
                                    if scale > 1.0 {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 2.0
                                        lastScale = 2.0
                                    }
                                }
                            }
                    }
                    #endif
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            #elseif os(macOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.borderedProminent)
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            #endif
        }
        .accessibilityLabel(alt.isEmpty ? "Full screen image" : alt)
        .accessibilityHint("Double tap to zoom, drag to pan, pinch to zoom")
    }
}

// MARK: - macOS-Specific Image Viewer

#if os(macOS)
private struct MacOSImageViewer: View {
    let imageData: Data
    let alt: String
    
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
                .ignoresSafeArea(.all)
            
            if let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = lastScale * value
                                }
                                .onEnded { value in
                                    lastScale = scale
                                    // Limit zoom out
                                    if scale < 1.0 {
                                        withAnimation(.easeInOut) {
                                            scale = 1.0
                                            lastScale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    }
                                    // Limit zoom in
                                    else if scale > 4.0 {
                                        withAnimation(.easeInOut) {
                                            scale = 4.0
                                            lastScale = 4.0
                                        }
                                    }
                                },
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { value in
                                    lastOffset = offset
                                }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut) {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
            }
            
            // Close button overlay
            VStack {
                HStack {
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
                Spacer()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .accessibilityLabel(alt.isEmpty ? "Full screen image" : alt)
        .accessibilityHint("Double click to zoom, drag to pan, scroll to zoom")
    }
}
#endif

// MARK: - Image Download Options Sheet

struct ImageDownloadOptionsSheet: View {
    let imageRef: SavedImageRef
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Image Details") {
                    if let sourceURL = imageRef.sourceURL {
                        Label(sourceURL.host() ?? "Unknown", systemImage: "globe")
                        
                        if imageRef.width > 0 && imageRef.height > 0 {
                            Label("\(imageRef.width) × \(imageRef.height)", systemImage: "aspectratio")
                        }
                        
                        Label(imageRef.downloadStatus.displayName, systemImage: "info.circle")
                    }
                }
                
                Section("Download Options") {
                    Button("Download This Image") {
                        Task {
                            await downloadImage()
                            dismiss()
                        }
                    }
                    .disabled(imageRef.hasLocalFile)
                    
                    if let domain = imageRef.domain {
                        Button("Always Download from \(domain)") {
                            Task {
                                await addToAlwaysDownload(domain: domain)
                                await downloadImage()
                                dismiss()
                            }
                        }
                        
                        Button("Never Download from \(domain)") {
                            Task {
                                await addToNeverDownload(domain: domain)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Image Options")
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
#if os(iOS)
        .presentationDetents([.medium, .large])
#endif
    }
    
    @MainActor
    private func downloadImage() async {
        guard let sourceURL = imageRef.sourceURL else { return }
        let settingsDescriptor = FetchDescriptor<ImageDownloadSettings>()
        guard let settings = try? modelContext.fetch(settingsDescriptor).first else { return }

        imageRef.markDownloadInProgress()
        try? modelContext.save()

        let imageCache = ImageCacheService.shared
        let outcome = await imageCache.downloadImageIfPermitted(
            from: sourceURL,
            settings: settings.snapshot(),
            uuid: imageRef.id
        )
        switch outcome {
        case .downloaded(_, let width, let height), .alreadyCached(_, let width, let height):
            imageRef.width = width
            imageRef.height = height
            imageRef.markDownloadSuccess()
        case .skipped:
            imageRef.downloadStatus = .skipped
        case .failed:
            imageRef.markDownloadFailure()
        }
        try? modelContext.save()
    }
    
    @MainActor
    private func addToAlwaysDownload(domain: String) async {
        let settingsDescriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = (try? modelContext.fetch(settingsDescriptor).first) ?? ImageDownloadSettings()
        
        settings.addToAlwaysDownload(domain)
        
        // Settings should already exist, just save changes
        try? modelContext.save()
    }
    
    @MainActor
    private func addToNeverDownload(domain: String) async {
        let settingsDescriptor = FetchDescriptor<ImageDownloadSettings>()
        let settings = (try? modelContext.fetch(settingsDescriptor).first) ?? ImageDownloadSettings()
        
        settings.addToNeverDownload(domain)
        
        // Settings should already exist, just save changes
        try? modelContext.save()
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        StowerImageView.small(uuid: UUID(), alt: "Small icon")
        StowerImageView.medium(uuid: UUID(), alt: "Medium graphic")
        StowerImageView.large(uuid: UUID(), alt: "Large content image")
    }
    .padding()
}
