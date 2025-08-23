import SwiftUI
import SwiftData
import MarkdownUI

public struct ReaderView: View {
    let itemId: UUID
    
    @Query private var items: [SavedItem]
    @State private var readerSettings = ReaderSettings()
    @State private var hasScrolledToLastPosition = false
    @State private var currentChunkIndex = 0
    @State private var showingReaderSettings = false
    @State private var isReprocessing = false
    
    public init(itemId: UUID) {
        self.itemId = itemId
        
        // Create a targeted query for this specific item
        let predicate = #Predicate<SavedItem> { item in
            item.id == itemId
        }
        _items = Query(filter: predicate)
    }
    
    private var item: SavedItem? {
        items.first
    }
    
    public var body: some View {
        Group {
            if let item = item {
                ScrollViewReader { proxy in
                    ScrollView {
                        SimpleMarkdownView(
                            item: item,
                            readerSettings: readerSettings,
                            onChunkVisible: { chunkIndex in
                                // Only update state if the value actually changed
                                if currentChunkIndex != chunkIndex {
                                    currentChunkIndex = chunkIndex
                                }
                                
                                // Trigger scroll restoration only once when the exact target chunk appears
                                if !hasScrolledToLastPosition && item.lastReadChunkIndex > 0 && chunkIndex == item.lastReadChunkIndex {
                                    print("🔄 Exact target chunk \(item.lastReadChunkIndex) appeared, attempting scroll restoration")
                                    hasScrolledToLastPosition = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation(.easeInOut(duration: 0.5)) {
                                            proxy.scrollTo("chunk_\(item.lastReadChunkIndex)", anchor: .top)
                                        }
                                    }
                                }
                            }
                        )
                    }
                    .onAppear {
                        print("📖 ReaderView appeared - LastReadChunkIndex: \(item.lastReadChunkIndex)")
                        
                        // Only try initial scroll if we haven't already scrolled and have a saved position
                        if !hasScrolledToLastPosition && item.lastReadChunkIndex > 0 {
                            print("🔄 Attempting initial scroll restoration to chunk \(item.lastReadChunkIndex)")
                            
                            // Try immediate scroll first (for chunks that render quickly)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    proxy.scrollTo("chunk_\(item.lastReadChunkIndex)", anchor: .top)
                                }
                                hasScrolledToLastPosition = true
                                print("✅ Initial scroll restoration completed")
                            }
                        } else if item.lastReadChunkIndex == 0 {
                            print("📄 Starting from beginning - no scroll restoration needed")
                            hasScrolledToLastPosition = true
                        }
                    }
                }
                .navigationTitle(item.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        reprocessButton
                        settingsButton
                    }
                    #elseif os(macOS)
                    ToolbarItemGroup(placement: .automatic) {
                        reprocessButton
                        settingsButton
                    }
                    #endif
                }
                .sheet(isPresented: $showingReaderSettings) {
                    ReaderSettingsView(readerSettings: $readerSettings)
                }
            } else {
                let _ = print("🐛 ReaderView: No item found for ID: \(itemId)")
                ContentUnavailableView(
                    "Article Not Found",
                    systemImage: "doc.text",
                    description: Text("The article you're looking for could not be found.")
                )
            }
        }
        .onAppear {
            print("🐛 ReaderView: ReaderView appeared, looking for item ID: \(itemId)")
            hasScrolledToLastPosition = false
        }
        .onDisappear {
            print("📖 ReaderView disappeared - saving scroll position: \(currentChunkIndex)")
            // Save scroll position when leaving the view to avoid constant SwiftData updates
            if let item = item {
                item.lastReadChunkIndex = currentChunkIndex
            }
        }
    }
    
    @ViewBuilder
    private var reprocessButton: some View {
        Button {
            if let item = item {
                Task {
                    await reprocessDocument(item)
                }
            }
        } label: {
            if isReprocessing {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isReprocessing)
        .help("Reprocess Document")
    }
    
    @ViewBuilder
    private var settingsButton: some View {
        Button {
            showingReaderSettings = true
        } label: {
            Image(systemName: "textformat")
        }
        .help("Reader Settings")
    }
    
    @MainActor
    private func reprocessDocument(_ item: SavedItem) async {
        isReprocessing = true
        
        do {
            print("🔄 Reprocessing document: \(item.title)")
            
            if let url = item.url {
                // Download content from URL
                let (data, response) = try await URLSession.shared.data(from: url)
                
                // Determine content type and process accordingly
                let mimeType = (response as? HTTPURLResponse)?.mimeType
                let contentService = ContentExtractionService()
                
                let extractedContent: ExtractedContent
                
                if mimeType == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
                    // Use PDF service directly
                    let pdfService = PDFExtractionService()
                    extractedContent = try await pdfService.extractContent(from: data)
                } else {
                    // Try to convert data to HTML string
                    let htmlString: String?
                    if let utf8String = String(data: data, encoding: .utf8) {
                        htmlString = utf8String
                    } else if let isoString = String(data: data, encoding: .isoLatin1) {
                        htmlString = isoString
                    } else if let asciiString = String(data: data, encoding: .ascii) {
                        htmlString = asciiString
                    } else {
                        htmlString = nil
                    }
                    
                    if let htmlString = htmlString {
                        extractedContent = try await contentService.extractContent(from: htmlString, baseURL: url)
                    } else {
                        throw NSError(domain: "ReprocessError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert downloaded data to string"])
                    }
                }
                
                // Process extracted content and images
                let processedMarkdown = await processImagesInContent(
                    extractedContent.markdown, 
                    imageURLs: extractedContent.images, 
                    baseURL: url
                )
                
                // Update the item with fresh content
                item.updateContent(
                    title: extractedContent.title.isEmpty ? item.title : extractedContent.title,
                    extractedMarkdown: processedMarkdown
                )
                
                print("✅ Document reprocessed successfully from URL")
            } else {
                print("⚠️ Cannot reprocess document - no URL available")
            }
        } catch {
            print("❌ Error reprocessing document: \(error)")
        }
        
        isReprocessing = false
    }
    
    // MARK: - Image Processing
    
    private func processImagesInContent(_ markdown: String, imageURLs: [String], baseURL: URL?) async -> String {
        // Extract image URLs from markdown directly
        let extractedImageURLs = extractImageURLsFromMarkdown(markdown)
        let allImageURLs = Set(imageURLs + extractedImageURLs)
        
        guard !allImageURLs.isEmpty else {
            print("📄 ReaderView: No images to process")
            return markdown
        }
        
        print("🖼️ ReaderView: Processing \(allImageURLs.count) images")
        
        let imageProcessor = ImageProcessingService()
        let imageCache = ImageCacheService.shared
        var updatedMarkdown = markdown
        
        // Process each image URL
        for imageURLString in allImageURLs {
            guard let imageURL = URL(string: imageURLString) else {
                print("❌ ReaderView: Invalid image URL: \(imageURLString)")
                continue
            }
            
            // Check if we already have this image cached
            if let existingUUID = imageCache.findUUID(for: imageURL) {
                print("🔄 ReaderView: Image already cached: \(existingUUID)")
                // Replace URL with token in markdown
                updatedMarkdown = updatedMarkdown.replacingOccurrences(
                    of: imageURL.absoluteString,
                    with: "stower://image/\(existingUUID)"
                )
                continue
            }
            
            do {
                // Download and process the image
                if let processedImage = try await imageProcessor.downloadAndProcess(url: imageURL) {
                    // Store in cache
                    if let uuid = await imageCache.store(
                        data: processedImage.data,
                        sourceURL: imageURL,
                        format: processedImage.format
                    ) {
                        print("✅ ReaderView: Cached image \(uuid) from \(imageURL.absoluteString)")
                        
                        // Replace URL with token in markdown
                        updatedMarkdown = updatedMarkdown.replacingOccurrences(
                            of: imageURL.absoluteString,
                            with: "stower://image/\(uuid)"
                        )
                    } else {
                        print("❌ ReaderView: Failed to cache processed image from \(imageURL.absoluteString)")
                    }
                } else {
                    print("❌ ReaderView: Failed to process image from \(imageURL.absoluteString)")
                }
            } catch {
                print("❌ ReaderView: Error processing image \(imageURL.absoluteString): \(error)")
            }
        }
        
        print("✅ ReaderView: Image processing complete")
        return updatedMarkdown
    }
    
    private func extractImageURLsFromMarkdown(_ markdown: String) -> [String] {
        let imagePattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        
        guard let regex = try? NSRegularExpression(pattern: imagePattern, options: []) else {
            print("❌ ReaderView: Failed to create regex for image extraction")
            return []
        }
        
        let matches = regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
        var imageURLs: [String] = []
        
        for match in matches {
            if match.numberOfRanges >= 3 {
                let urlRange = Range(match.range(at: 2), in: markdown)!
                let urlString = String(markdown[urlRange])
                
                // Skip data URLs and stower tokens - we only want http(s) URLs
                if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                    imageURLs.append(urlString)
                }
            }
        }
        
        print("📷 ReaderView: Extracted \(imageURLs.count) image URLs from markdown")
        return imageURLs
    }
}