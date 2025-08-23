import Foundation
import SwiftData

@MainActor
public class BackgroundProcessor: Observable {
    private let modelContext: ModelContext
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
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
                    baseURL: url
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
    
    private func processImagesInContent(_ markdown: String, imageURLs: [String], baseURL: URL?) async -> String {
        // Extract image URLs from markdown directly
        let extractedImageURLs = extractImageURLsFromMarkdown(markdown)
        let allImageURLs = Set(imageURLs + extractedImageURLs)
        
        guard !allImageURLs.isEmpty else {
            print("📄 BackgroundProcessor: No images to process")
            return markdown
        }
        
        print("🖼️ BackgroundProcessor: Processing \(allImageURLs.count) images")
        
        let imageProcessor = ImageProcessingService()
        let imageCache = ImageCacheService.shared
        var updatedMarkdown = markdown
        
        // Process each image URL
        for imageURLString in allImageURLs {
            guard let imageURL = URL(string: imageURLString) else {
                print("❌ BackgroundProcessor: Invalid image URL: \(imageURLString)")
                continue
            }
            
            // Check if we already have this image cached
            if let existingUUID = imageCache.findUUID(for: imageURL) {
                print("🔄 BackgroundProcessor: Image already cached: \(existingUUID)")
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
                        print("✅ BackgroundProcessor: Cached image \(uuid) from \(imageURL.absoluteString)")
                        
                        // Replace URL with token in markdown
                        updatedMarkdown = updatedMarkdown.replacingOccurrences(
                            of: imageURL.absoluteString,
                            with: "stower://image/\(uuid)"
                        )
                    } else {
                        print("❌ BackgroundProcessor: Failed to cache processed image from \(imageURL.absoluteString)")
                    }
                } else {
                    print("❌ BackgroundProcessor: Failed to process image from \(imageURL.absoluteString)")
                }
            } catch {
                print("❌ BackgroundProcessor: Error processing image \(imageURL.absoluteString): \(error)")
            }
        }
        
        print("✅ BackgroundProcessor: Image processing complete")
        return updatedMarkdown
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
