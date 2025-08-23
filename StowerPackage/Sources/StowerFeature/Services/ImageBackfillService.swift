import Foundation
import SwiftData
import SwiftUI

/// Service for converting legacy images to the new sync-friendly model system
@MainActor
public class ImageBackfillService: Observable {
    private let modelContext: ModelContext
    private let imageCache = ImageCacheService.shared
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    /// Converts legacy base64 images and [UUID: Data] images to new model format
    public func backfillLegacyImages() async {
        print("🔄 ImageBackfillService: Starting legacy image backfill...")
        
        // Fetch all SavedItems that might have legacy images
        let descriptor = FetchDescriptor<SavedItem>()
        
        do {
            let items = try modelContext.fetch(descriptor)
            var processedCount = 0
            var convertedCount = 0
            
            for item in items {
                let converted = await backfillImagesForItem(item)
                processedCount += 1
                if converted {
                    convertedCount += 1
                }
                
                // Save periodically to avoid memory issues
                if processedCount % 10 == 0 {
                    try? modelContext.save()
                }
            }
            
            // Final save
            try? modelContext.save()
            
            print("✅ ImageBackfillService: Completed backfill for \(processedCount) items, converted \(convertedCount) items")
            
        } catch {
            print("❌ ImageBackfillService: Error during backfill: \(error)")
        }
    }
    
    /// Backfills images for a single SavedItem
    private func backfillImagesForItem(_ item: SavedItem) async -> Bool {
        var hasChanges = false
        
        // 1. Convert base64 images in markdown to SavedImageAssets
        if item.extractedMarkdown.contains("data:image") {
            print("🖼️ ImageBackfillService: Converting base64 images in markdown for item: \(item.title)")
            let migratedMarkdown = await convertBase64ImagesToAssets(item.extractedMarkdown, for: item)
            if migratedMarkdown != item.extractedMarkdown {
                item.extractedMarkdown = migratedMarkdown
                hasChanges = true
            }
        }
        
        // 2. Convert legacy [UUID: Data] images to SavedImageAssets
        if !item.images.isEmpty {
            print("🖼️ ImageBackfillService: Converting legacy UUID:Data images for item: \(item.title)")
            await convertLegacyImagesToAssets(item.images, for: item)
            
            // Clear the legacy images after conversion
            item.images = [:]
            hasChanges = true
        }
        
        // 3. Extract web image URLs from markdown and create SavedImageRefs
        let webImageCount = await extractWebImageReferences(from: item.extractedMarkdown, for: item)
        if webImageCount > 0 {
            print("🖼️ ImageBackfillService: Created \(webImageCount) web image references for item: \(item.title)")
            hasChanges = true
        }
        
        if hasChanges {
            item.dateModified = Date()
        }
        
        return hasChanges
    }
    
    /// Converts base64 images in markdown to SavedImageAssets and returns updated markdown
    private func convertBase64ImagesToAssets(_ markdown: String, for item: SavedItem) async -> String {
        let base64Pattern = #"!\[([^\]]*)\]\(data:image/([^;]+);base64,([^)]+)\)"#
        
        guard let regex = try? NSRegularExpression(pattern: base64Pattern, options: []) else {
            print("❌ ImageBackfillService: Failed to create regex for base64 conversion")
            return markdown
        }
        
        var convertedMarkdown = markdown
        let matches = regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
        
        // Process matches in reverse order to avoid range issues
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            
            let fullMatchRange = Range(match.range(at: 0), in: markdown)!
            let altRange = Range(match.range(at: 1), in: markdown)!
            let mimeTypeRange = Range(match.range(at: 2), in: markdown)!
            let base64Range = Range(match.range(at: 3), in: markdown)!
            
            let fullMatch = String(markdown[fullMatchRange])
            let altText = String(markdown[altRange])
            let mimeType = String(markdown[mimeTypeRange])
            let base64String = String(markdown[base64Range])
            
            // Decode base64
            if let imageData = Data(base64Encoded: base64String) {
                // Determine format from MIME type
                let format = mimeType.contains("png") ? "png" : "jpg"
                
                // Create SavedImageAsset
                let imageAsset = await SavedImageAsset.create(
                    from: imageData,
                    origin: .migrated,
                    fileFormat: format,
                    altText: altText
                )
                
                // Add to item
                item.addImageAsset(imageAsset)
                
                // Also store in cache for immediate availability
                _ = await imageCache.store(data: imageData, format: format)
                
                // Replace with stower token
                let tokenReplacement = "![" + altText + "](stower://image/\(imageAsset.id))"
                convertedMarkdown = convertedMarkdown.replacingOccurrences(of: fullMatch, with: tokenReplacement)
                
                print("✅ ImageBackfillService: Converted base64 image to asset: \(imageAsset.id)")
            } else {
                print("❌ ImageBackfillService: Failed to decode base64 image data")
            }
        }
        
        return convertedMarkdown
    }
    
    /// Converts legacy [UUID: Data] images to SavedImageAssets
    private func convertLegacyImagesToAssets(_ legacyImages: [UUID: Data], for item: SavedItem) async {
        for (uuid, imageData) in legacyImages {
            // Create SavedImageAsset from legacy data
            let imageAsset = await SavedImageAsset.create(
                from: imageData,
                origin: .migrated,
                fileFormat: "jpg", // Assume jpg for legacy images
                altText: ""
            )
            
            // Override the ID to match the legacy UUID for consistency
            imageAsset.id = uuid
            
            // Add to item
            item.addImageAsset(imageAsset)
            
            // Store in cache for immediate availability
            _ = await imageCache.store(data: imageData, format: "jpg")
            
            print("✅ ImageBackfillService: Converted legacy image \(uuid) to asset")
        }
    }
    
    /// Extracts web image URLs from markdown and creates SavedImageRefs
    private func extractWebImageReferences(from markdown: String, for item: SavedItem) async -> Int {
        let imagePattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        
        guard let regex = try? NSRegularExpression(pattern: imagePattern, options: []) else {
            print("❌ ImageBackfillService: Failed to create regex for web image extraction")
            return 0
        }
        
        let matches = regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
        var createdCount = 0
        
        for match in matches {
            if match.numberOfRanges >= 3 {
                let urlRange = Range(match.range(at: 2), in: markdown)!
                let urlString = String(markdown[urlRange])
                
                // Only process http/https URLs (not stower tokens or data URLs)
                if urlString.hasPrefix("http://") || urlString.hasPrefix("https://"),
                   let url = URL(string: urlString) {
                    
                    // Check if we already have a reference for this URL
                    let existingRef = (item.imageRefs ?? []).first { $0.sourceURL == url }
                    if existingRef == nil {
                        // Create new image reference
                        let imageRef = SavedImageRef(
                            sourceURL: url,
                            origin: .web
                        )
                        
                        // Check cache for existing image
                        if let existingUUID = imageCache.findUUID(for: url) {
                            imageRef.hasLocalFile = true
                            imageRef.downloadStatus = .completed
                            
                            if let metadata = imageCache.metadata(for: existingUUID) {
                                imageRef.width = metadata.width
                                imageRef.height = metadata.height
                            }
                        }
                        
                        item.addImageRef(imageRef)
                        createdCount += 1
                        
                        print("✅ ImageBackfillService: Created image ref \(imageRef.id) for \(url.absoluteString)")
                    }
                }
            }
        }
        
        return createdCount
    }
    
    /// Checks if backfill is needed for any items in the database
    public func needsBackfill() async -> Bool {
        let descriptor = FetchDescriptor<SavedItem>()
        
        do {
            let items = try modelContext.fetch(descriptor)
            
            for item in items {
                // Check for base64 images in markdown
                if item.extractedMarkdown.contains("data:image") {
                    return true
                }
                
                // Check for legacy [UUID: Data] images
                if !item.images.isEmpty {
                    return true
                }
                
                // Check for unprocessed web images (markdown has http URLs but no refs)
                let hasWebImages = item.extractedMarkdown.contains("](http")
                let hasImageRefs = !(item.imageRefs ?? []).isEmpty
                if hasWebImages && !hasImageRefs {
                    return true
                }
            }
            
            return false
        } catch {
            print("❌ ImageBackfillService: Error checking backfill need: \(error)")
            return true // Err on the side of caution
        }
    }
    
    /// Returns progress information for backfill operation
    public func getBackfillProgress() async -> BackfillProgress {
        let descriptor = FetchDescriptor<SavedItem>()
        
        do {
            let items = try modelContext.fetch(descriptor)
            let totalItems = items.count
            var needsBackfillCount = 0
            var base64Count = 0
            var legacyImagesCount = 0
            var missingRefsCount = 0
            
            for item in items {
                var itemNeedsBackfill = false
                
                if item.extractedMarkdown.contains("data:image") {
                    base64Count += 1
                    itemNeedsBackfill = true
                }
                
                if !item.images.isEmpty {
                    legacyImagesCount += 1
                    itemNeedsBackfill = true
                }
                
                let hasWebImages = item.extractedMarkdown.contains("](http")
                let hasImageRefs = !(item.imageRefs ?? []).isEmpty
                if hasWebImages && !hasImageRefs {
                    missingRefsCount += 1
                    itemNeedsBackfill = true
                }
                
                if itemNeedsBackfill {
                    needsBackfillCount += 1
                }
            }
            
            return BackfillProgress(
                totalItems: totalItems,
                needsBackfill: needsBackfillCount,
                base64Images: base64Count,
                legacyImages: legacyImagesCount,
                missingRefs: missingRefsCount
            )
        } catch {
            print("❌ ImageBackfillService: Error getting backfill progress: \(error)")
            return BackfillProgress(totalItems: 0, needsBackfill: 0, base64Images: 0, legacyImages: 0, missingRefs: 0)
        }
    }
}

/// Progress information for backfill operation
public struct BackfillProgress {
    public let totalItems: Int
    public let needsBackfill: Int
    public let base64Images: Int
    public let legacyImages: Int
    public let missingRefs: Int
    
    public var isComplete: Bool {
        needsBackfill == 0
    }
    
    public var progressPercentage: Double {
        guard totalItems > 0 else { return 1.0 }
        let completed = totalItems - needsBackfill
        return Double(completed) / Double(totalItems)
    }
}
