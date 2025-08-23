import Foundation
import SwiftData

@MainActor
public class BackgroundProcessor: Observable {
    private let modelContext: ModelContext
    private var imageDownloadSettings: ImageDownloadSettings?
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadImageDownloadSettings()
    }
    
    private func loadImageDownloadSettings() {
        let descriptor = FetchDescriptor<ImageDownloadSettings>()
        do {
            let settings = try modelContext.fetch(descriptor)
            if let firstSetting = settings.first {
                // Ensure correct defaults are set (fix any bad existing settings)
                if !firstSetting.globalAutoDownload || firstSetting.askForNewDomains {
                    print("🔧 BackgroundProcessor: Fixing image download settings - enabling auto-download")
                    firstSetting.globalAutoDownload = true
                    firstSetting.askForNewDomains = false
                    try? modelContext.save()
                }
                imageDownloadSettings = firstSetting
            } else {
                // Create default settings with auto-download enabled
                let defaultSettings = ImageDownloadSettings(
                    globalAutoDownload: true,
                    askForNewDomains: false
                )
                modelContext.insert(defaultSettings)
                imageDownloadSettings = defaultSettings
                try? modelContext.save()
                print("✅ BackgroundProcessor: Created default image download settings with auto-download enabled")
            }
        } catch {
            print("❌ BackgroundProcessor: Error loading image download settings: \(error)")
            // Create default settings as fallback
            imageDownloadSettings = ImageDownloadSettings(
                globalAutoDownload: true,
                askForNewDomains: false
            )
        }
    }
    
    private func getImageDownloadSettings() -> ImageDownloadSettings {
        if let settings = imageDownloadSettings {
            return settings
        }
        
        // Fallback: try to load again
        loadImageDownloadSettings()
        return imageDownloadSettings ?? ImageDownloadSettings()
    }
    
    public func processPendingJobs() {
        let defaults = UserDefaults(suiteName: "group.com.ryanleewilliams.stower") ?? UserDefaults.standard
        
        guard let pendingJobs = defaults.array(forKey: "pendingProcessingJobs") as? [[String: String]],
              !pendingJobs.isEmpty else {
            return
        }
        
        // Clear the pending jobs immediately to avoid reprocessing
        defaults.removeObject(forKey: "pendingProcessingJobs")
        
        for job in pendingJobs {
            guard let idString = job["id"],
                  let urlString = job["url"],
                  let id = UUID(uuidString: idString),
                  let url = URL(string: urlString) else {
                continue
            }
            
            processJob(id: id, url: url)
        }
    }
    
    /// Migrates existing SavedItems that have cached images but no SavedImageRef objects
    public func migrateExistingImageReferences() {
        print("🔄 BackgroundProcessor: Starting image reference migration")
        
        // Ensure image download settings exist with auto-download enabled
        loadImageDownloadSettings()
        
        Task {
            await performImageRefMigration()
            await retryFailedDeletions()
        }
    }
    
    /// Retry any failed deletions that may not have synced to CloudKit
    private func retryFailedDeletions() async {
        let deletionService = DeletionService(modelContext: modelContext)
        await deletionService.retryFailedDeletions()
    }
    
    private func performImageRefMigration() async {
        // Get all saved items
        let itemsDescriptor = FetchDescriptor<SavedItem>()
        do {
            let items = try modelContext.fetch(itemsDescriptor)
            let imageCache = ImageCacheService.shared
            var migratedCount = 0
            
            for item in items {
                // Check if item has image tokens in markdown but no image refs
                let hasImageTokens = item.extractedMarkdown.contains("stower://image/")
                let hasImageRefs = !(item.imageRefs?.isEmpty ?? true)
                
                if hasImageTokens && !hasImageRefs {
                    print("🔍 BackgroundProcessor: Migrating image refs for item: \(item.title)")
                    
                    // Extract image UUIDs from markdown
                    let imageUUIDs = extractImageUUIDs(from: item.extractedMarkdown)
                    
                    for imageUUID in imageUUIDs {
                        // Check if we have metadata for this image
                        if let metadata = imageCache.metadata(for: imageUUID) {
                            // Create SavedImageRef
                            let imageRef = SavedImageRef(
                                id: imageUUID,
                                sourceURL: metadata.sourceURL != nil ? URL(string: metadata.sourceURL!) : nil,
                                width: metadata.width,
                                height: metadata.height,
                                origin: .web,
                                fileFormat: metadata.filename.hasSuffix(".png") ? "png" : "jpg"
                            )
                            
                            imageRef.markDownloadSuccess()
                            item.addImageRef(imageRef)
                            migratedCount += 1
                            
                            print("✅ BackgroundProcessor: Created SavedImageRef for cached image \(imageUUID)")
                        }
                    }
                }
            }
            
            if migratedCount > 0 {
                try? modelContext.save()
                print("✅ BackgroundProcessor: Migration complete. Created \(migratedCount) SavedImageRef objects")
            } else {
                print("✅ BackgroundProcessor: No items needed migration")
            }
            
        } catch {
            print("❌ BackgroundProcessor: Migration failed: \(error)")
        }
    }
    
    private func extractImageUUIDs(from markdown: String) -> [UUID] {
        let pattern = #"stower://image/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            print("❌ BackgroundProcessor: Failed to create regex for UUID extraction")
            return []
        }
        
        let matches = regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
        var uuids: [UUID] = []
        
        for match in matches {
            if match.numberOfRanges >= 2 {
                let uuidRange = Range(match.range(at: 1), in: markdown)!
                let uuidString = String(markdown[uuidRange])
                
                if let uuid = UUID(uuidString: uuidString) {
                    uuids.append(uuid)
                }
            }
        }
        
        return uuids
    }
    
    private func processJob(id: UUID, url: URL) {
        // Find the SavedItem by ID
        let descriptor = FetchDescriptor<SavedItem>(
            predicate: #Predicate<SavedItem> { item in
                item.id == id
            }
        )
        
        do {
            let items = try modelContext.fetch(descriptor)
            guard let item = items.first else {
                print("Could not find saved item with ID: \(id)")
                return
            }
            
            // Process the URL in the background
            Task {
                await processURL(for: item, url: url)
            }
        } catch {
            print("Error fetching saved item: \(error)")
        }
    }
    
    private func processURL(for item: SavedItem, url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Try multiple encodings to handle different websites
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
                item.rawHTML = htmlString
                
                // Use ContentExtractionService for smart extraction
                let contentService = ContentExtractionService()
                let extractedContent = try await contentService.extractContent(from: htmlString, baseURL: url)
                
                // Process extracted content and images
                let processedMarkdown = await processImagesInContent(
                    extractedContent.markdown, 
                    imageURLs: extractedContent.images, 
                    baseURL: url,
                    for: item
                )
                
                item.updateContent(
                    title: extractedContent.title,
                    extractedMarkdown: processedMarkdown
                )
                
                // Save the updated item
                try modelContext.save()
                
            }
        } catch {
            item.updateContent(
                title: "Failed to Load",
                extractedMarkdown: "Failed to fetch content from URL: \(error.localizedDescription)"
            )
            
            try? modelContext.save()
        }
    }
    
    // MARK: - Image Processing
    
    private func processImagesInContent(_ markdown: String, imageURLs: [String], baseURL: URL?, for item: SavedItem) async -> String {
        // Extract image URLs from markdown directly
        let extractedImageURLs = extractImageURLsFromMarkdown(markdown)
        let allImageURLs = Set(imageURLs + extractedImageURLs)
        
        guard !allImageURLs.isEmpty else {
            print("📄 BackgroundProcessor: No images to process")
            return markdown
        }
        
        print("🖼️ BackgroundProcessor: Processing \(allImageURLs.count) images")
        
        let settings = getImageDownloadSettings()
        var updatedMarkdown = markdown
        
        // Process each image URL
        for imageURLString in allImageURLs {
            guard let imageURL = URL(string: imageURLString) else {
                print("❌ BackgroundProcessor: Invalid image URL: \(imageURLString)")
                continue
            }
            
            // Create or find existing image reference
            let imageRef = await createImageReference(for: imageURL, item: item)
            
            // Replace URL with token in markdown
            updatedMarkdown = updatedMarkdown.replacingOccurrences(
                of: imageURL.absoluteString,
                with: "stower://image/\(imageRef.id)"
            )
            
            // Check if we should download this image
            let decision = item.getImageDownloadDecision(globalSettings: settings)
            if decision.shouldDownload && !imageRef.hasLocalFile {
                // Attempt download without capturing model objects
                let snapshot = settings.snapshot()
                let imageRefID = imageRef.id
                Task {
                    await downloadImageInBackground(imageRefID: imageRefID, sourceURL: imageURL, settings: snapshot)
                }
            } else {
                print("⏭️ BackgroundProcessor: Skipping immediate download for \(imageURL.absoluteString): \(decision.reason)")
                // Keep pending to allow user-initiated download later
                imageRef.downloadStatus = .pending
            }
        }
        
        print("✅ BackgroundProcessor: Image processing complete")
        return updatedMarkdown
    }
    
    /// Creates or finds an existing image reference for a URL
    private func createImageReference(for url: URL, item: SavedItem) async -> SavedImageRef {
        // Check if we already have a reference for this URL and item
        for existingRef in (item.imageRefs ?? []) {
            if existingRef.sourceURL == url {
                print("🔄 BackgroundProcessor: Found existing image ref: \(existingRef.id)")
                return existingRef
            }
        }
        
        // Create new image reference
        let imageRef = SavedImageRef(
            sourceURL: url,
            origin: .web
        )
        
        // Check if image already exists in cache
        let imageCache = ImageCacheService.shared
        if let existingUUID = imageCache.findUUID(for: url) {
            imageRef.hasLocalFile = true
            imageRef.downloadStatus = .completed
            
            // Get metadata from cache if available
            if let metadata = imageCache.metadata(for: existingUUID) {
                imageRef.width = metadata.width
                imageRef.height = metadata.height
            }
        }
        
        item.addImageRef(imageRef)
        
        print("✅ BackgroundProcessor: Created image ref \(imageRef.id) for \(url.absoluteString)")
        return imageRef
    }
    
    /// Downloads an image in the background
    private func downloadImageInBackground(imageRefID: UUID, sourceURL: URL, settings: ImageDownloadSettingsSnapshot) async {
        // Mark as in-progress on main actor
        if let ref = try? modelContext.fetch(
            FetchDescriptor<SavedImageRef>(predicate: #Predicate<SavedImageRef> { $0.id == imageRefID })
        ).first {
            ref.markDownloadInProgress()
            try? modelContext.save()
        }

        let imageCache = ImageCacheService.shared
        let outcome = await imageCache.downloadImageIfPermitted(from: sourceURL, settings: settings)

        // Update model on main actor
        if let ref = try? modelContext.fetch(
            FetchDescriptor<SavedImageRef>(predicate: #Predicate<SavedImageRef> { $0.id == imageRefID })
        ).first {
            switch outcome {
            case .downloaded(_, let width, let height), .alreadyCached(_, let width, let height):
                ref.width = width
                ref.height = height
                ref.markDownloadSuccess()
                print("✅ BackgroundProcessor: Successfully processed image \(imageRefID)")
            case .skipped(let reason):
                ref.downloadStatus = .skipped
                print("⏭️ BackgroundProcessor: Skipped download for \(imageRefID): \(reason)")
            case .failed(let error):
                ref.markDownloadFailure()
                print("❌ BackgroundProcessor: Failed to download image \(imageRefID): \(error)")
            }
            try? modelContext.save()
        }
    }
    
    /// Downloads an image in the background (old version - to be replaced)
    private func downloadImageInBackgroundOld(imageRef: SavedImageRef, settings: ImageDownloadSettings) async {
        // This is now handled in the main downloadImageInBackground method
    }
    
    /// Processes pending image downloads for synced items
    public func processPendingImageDownloads() async {
        let settings = getImageDownloadSettings()
        
        // Find all image references that are candidates (we'll check local bytes per-device)
        let descriptor = FetchDescriptor<SavedImageRef>(
            predicate: #Predicate<SavedImageRef> { imageRef in
                imageRef.downloadStatusRaw != "inProgress" && imageRef.downloadStatusRaw != "skipped" && imageRef.sourceURL != nil
            }
        )
        
        do {
            let pendingImageRefs = try modelContext.fetch(descriptor)
            
            guard !pendingImageRefs.isEmpty else {
                print("📄 BackgroundProcessor: No pending image downloads")
                return
            }
            
            print("🖼️ BackgroundProcessor: Processing \(pendingImageRefs.count) pending image downloads")
            
            let imageCache = ImageCacheService.shared
            // Process images sequentially to avoid concurrency issues
            for imageRef in pendingImageRefs {
                guard let url = imageRef.sourceURL else { continue }
                let alreadyLocal = imageCache.findUUID(for: url) != nil
                if alreadyLocal {
                    imageRef.markDownloadSuccess()
                    continue
                }
                switch imageRef.downloadStatus {
                case .completed, .skipped:
                    // Completed on another device; bytes not local here. Treat as pending locally.
                    await downloadImageInBackground(
                        imageRefID: imageRef.id,
                        sourceURL: url,
                        settings: settings.snapshot()
                    )
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                case .inProgress:
                    // Let in-flight downloads finish
                    continue
                case .failed:
                    if imageRef.shouldRetryDownload {
                        await downloadImageInBackground(
                            imageRefID: imageRef.id,
                            sourceURL: url,
                            settings: settings.snapshot()
                        )
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                case .pending:
                    await downloadImageInBackground(
                        imageRefID: imageRef.id,
                        sourceURL: url,
                        settings: settings.snapshot()
                    )
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            
            print("✅ BackgroundProcessor: Completed processing pending image downloads")
            
        } catch {
            print("❌ BackgroundProcessor: Error processing pending image downloads: \(error)")
        }
    }
    
    private func extractImageURLsFromMarkdown(_ markdown: String) -> [String] {
        let imagePattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        
        guard let regex = try? NSRegularExpression(pattern: imagePattern, options: []) else {
            print("❌ BackgroundProcessor: Failed to create regex for image extraction")
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
        
        print("📷 BackgroundProcessor: Extracted \(imageURLs.count) image URLs from markdown")
        return imageURLs
    }
}

// MARK: - Array Extension for Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
