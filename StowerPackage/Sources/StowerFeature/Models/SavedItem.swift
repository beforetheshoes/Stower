import Foundation
import SwiftData
import SwiftUI

@Model
public final class SavedItem {
    public var id: UUID = UUID()
    public var url: URL?
    public var title: String = ""
    public var author: String = ""
    
    // HTML and large binary data kept in external storage
    @Attribute(.externalStorage)
    public var rawHTML: String?
    
    // Markdown should be fast to access - remove external storage
    public var extractedMarkdown: String = ""
    
    // Keep large binary image data in external storage (legacy)
    @Attribute(.externalStorage)
    public var images: [UUID: Data] = [:]
    
    // New image models for sync-friendly storage
    @Relationship(deleteRule: .cascade, inverse: \SavedImageRef.item)
    public var imageRefs: [SavedImageRef]? = nil
    
    @Relationship(deleteRule: .cascade, inverse: \SavedImageAsset.item) 
    public var imageAssets: [SavedImageAsset]? = nil
    
    // Image download preference for this specific item
    public var imageDownloadPreference: ItemImagePreference = ItemImagePreference.auto
    
    public var coverImageId: UUID?
    public var dateAdded: Date = Date()
    public var dateModified: Date = Date()
    public var tags: [String] = []
    
    // Lightweight preview text for list views
    public var contentPreview: String = ""
    
    // Scroll position restoration
    public var lastReadChunkIndex: Int = 0
    
    public init(
        url: URL? = nil,
        title: String,
        author: String = "",
        rawHTML: String? = nil,
        extractedMarkdown: String,
        images: [UUID: Data] = [:],
        coverImageId: UUID? = nil,
        tags: [String] = [],
        imageDownloadPreference: ItemImagePreference = .auto
    ) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.author = author
        self.rawHTML = rawHTML
        self.extractedMarkdown = extractedMarkdown
        self.images = images
        self.imageDownloadPreference = imageDownloadPreference
        self.coverImageId = coverImageId
        self.dateAdded = Date()
        self.dateModified = Date()
        self.tags = tags
        self.contentPreview = Self.generatePreview(from: extractedMarkdown)
    }
    
    public func updateContent(
        title: String? = nil,
        author: String? = nil,
        extractedMarkdown: String? = nil,
        images: [UUID: Data]? = nil,
        coverImageId: UUID? = nil,
        tags: [String]? = nil,
        imageDownloadPreference: ItemImagePreference? = nil
    ) {
        if let title = title {
            self.title = title
        }
        if let author = author {
            self.author = author
        }
        if let extractedMarkdown = extractedMarkdown {
            self.extractedMarkdown = extractedMarkdown
            self.contentPreview = Self.generatePreview(from: extractedMarkdown)
        }
        if let images = images {
            self.images = images
            // If cover image ID is not in the new images, clear it
            if let currentCoverImageId = self.coverImageId,
               !images.keys.contains(currentCoverImageId) {
                self.coverImageId = nil
            }
        }
        if let coverImageId = coverImageId {
            self.coverImageId = coverImageId
        }
        if let tags = tags {
            self.tags = tags
        }
        if let imageDownloadPreference = imageDownloadPreference {
            self.imageDownloadPreference = imageDownloadPreference
        }
        self.dateModified = Date()
    }
    
    // MARK: - Image Management
    
    /// Returns all images for this item (both legacy and new formats)
    public var allImages: [UUID] {
        var imageIds: [UUID] = []
        
        // Add legacy images
        imageIds.append(contentsOf: images.keys)
        
        // Add new format images
        imageIds.append(contentsOf: (imageRefs ?? []).map { $0.id })
        imageIds.append(contentsOf: (imageAssets ?? []).map { $0.id })
        
        return imageIds
    }
    
    /// Gets the domain for this item if it has a URL
    public var domain: String? {
        return url?.host()
    }
    
    /// Determines if images should be downloaded based on item preference and global settings
    public func shouldDownloadImages(globalSettings: ImageDownloadSettings) -> Bool {
        switch imageDownloadPreference {
        case .always:
            return true
        case .never:
            return false
        case .ask:
            return false  // Requires user interaction
        case .auto:
            let decision = globalSettings.shouldDownloadImages(for: domain)
            return decision.shouldDownload
        }
    }
    
    /// Gets the effective image download preference for this item
    public func getImageDownloadDecision(globalSettings: ImageDownloadSettings) -> ImageDownloadDecision {
        switch imageDownloadPreference {
        case .always:
            return .download("Item preference: Always")
        case .never:
            return .skip("Item preference: Never")
        case .ask:
            return .ask("Item preference: Ask")
        case .auto:
            return globalSettings.shouldDownloadImages(for: domain)
        }
    }
    
    /// Adds an image reference for web images
    public func addImageRef(_ imageRef: SavedImageRef) {
        imageRef.item = self
        if imageRefs == nil { imageRefs = [] }
        imageRefs!.append(imageRef)
        dateModified = Date()
    }
    
    /// Adds an image asset for PDF/pasted images
    public func addImageAsset(_ imageAsset: SavedImageAsset) {
        imageAsset.item = self
        if imageAssets == nil { imageAssets = [] }
        imageAssets!.append(imageAsset)
        dateModified = Date()
    }
    
    // MARK: - Image Migration Support
    
    /// Returns migrated markdown with base64 images converted to tokens
    @MainActor
    public var migratedMarkdown: String {
        get async {
            if extractedMarkdown.contains("data:image") {
                print("🔄 SavedItem: Migrating base64 images to tokens for item: \(title)")
                let migrated = await migrateBase64ToTokens(extractedMarkdown)
                
                // Update the stored markdown if migration produced changes
                if migrated != extractedMarkdown {
                    self.extractedMarkdown = migrated
                    self.dateModified = Date()
                    print("✅ SavedItem: Migration complete, updated stored markdown")
                }
                
                return migrated
            }
            return extractedMarkdown
        }
    }
    
    @MainActor
    private func migrateBase64ToTokens(_ markdown: String) async -> String {
        let base64Pattern = #"!\[([^\]]*)\]\(data:image/([^;]+);base64,([^)]+)\)"#
        
        guard let regex = try? NSRegularExpression(pattern: base64Pattern, options: []) else {
            print("❌ SavedItem: Failed to create regex for base64 migration")
            return markdown
        }
        
        var migratedMarkdown = markdown
        let matches = regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
        
        let imageCache = ImageCacheService.shared
        
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
                
                // Create SavedImageAsset for sync-friendly storage
                let imageAsset = await SavedImageAsset.create(
                    from: imageData,
                    origin: .migrated,
                    fileFormat: format,
                    altText: altText
                )
                
                // Add to this item
                addImageAsset(imageAsset)
                
                // Also store in cache for immediate availability
                _ = await imageCache.store(data: imageData, format: format)
                
                let tokenReplacement = "![" + altText + "](stower://image/\(imageAsset.id))"
                migratedMarkdown = migratedMarkdown.replacingOccurrences(of: fullMatch, with: tokenReplacement)
                print("✅ SavedItem: Migrated base64 image to asset: \(imageAsset.id)")
            } else {
                print("❌ SavedItem: Failed to decode base64 image data")
            }
        }
        
        return migratedMarkdown
    }
    
    // These computed properties access external storage and cause disk I/O
    // Only use them when you actually need the image data, not in list rows
    public func hasImages() async -> Bool {
        !images.isEmpty
    }
    
    public func coverImageData() async -> Data? {
        guard let coverImageId = coverImageId else {
            return images.values.first
        }
        return images[coverImageId]
    }
    
    public func hasCoverImage() async -> Bool {
        await coverImageData() != nil
    }
    
    public var isFromURL: Bool {
        url != nil
    }
    
    // MARK: - Content Preview Generation
    
    /// Generates a lightweight preview text from markdown without loading the full content
    public static func generatePreview(from markdown: String) -> String {
        // Remove markdown formatting and extract first ~150 characters
        let cleanText = markdown
            .replacingOccurrences(of: #"!\[.*?\]\(.*?\)"#, with: "", options: .regularExpression) // Remove images
            .replacingOccurrences(of: #"#{1,6}\s+"#, with: "", options: .regularExpression) // Remove headers
            .replacingOccurrences(of: #"\*{1,2}(.*?)\*{1,2}"#, with: "$1", options: .regularExpression) // Remove bold/italic
            .replacingOccurrences(of: #"`(.*?)`"#, with: "$1", options: .regularExpression) // Remove code
            .replacingOccurrences(of: #"\[(.*?)\]\(.*?\)"#, with: "$1", options: .regularExpression) // Remove links, keep text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let previewLength = 150
        if cleanText.count <= previewLength {
            return cleanText
        }
        
        // Find a good breaking point (word boundary)
        let truncated = String(cleanText.prefix(previewLength))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "…"
        }
        
        return truncated + "…"
    }
}

public enum ItemImagePreference: String, Codable, CaseIterable, Sendable {
    case auto = "auto"        // Use global/domain settings
    case always = "always"    // Always download for this item
    case never = "never"      // Never download for this item  
    case ask = "ask"          // Ask user each time
    
    public var displayName: String {
        switch self {
        case .auto: return "Use Settings"
        case .always: return "Always Download"
        case .never: return "Never Download"
        case .ask: return "Ask Each Time"
        }
    }
    
    public var systemImage: String {
        switch self {
        case .auto: return "gear"
        case .always: return "checkmark.circle.fill"
        case .never: return "xmark.circle.fill"
        case .ask: return "questionmark.circle.fill"
        }
    }
}

extension SavedItem {
    @MainActor
    public static let preview = SavedItem(
        url: URL(string: "https://example.com/article"),
        title: "Sample Article",
        author: "Sample Author",
        extractedMarkdown: """
        # Sample Article
        
        This is a sample article with some **bold text** and *italic text*.
        
        ![Sample Image](image://sample-uuid)
        
        Here's a list:
        - Item 1
        - Item 2
        - Item 3
        """,
        tags: ["tech", "sample"]
    )
}
