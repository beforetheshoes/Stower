import Foundation
import SwiftData
import SwiftUI

@Model
public final class SavedItem {
    public var id: UUID = UUID()
    public var url: URL?
    public var title: String = ""
    
    // HTML and large binary data kept in external storage
    @Attribute(.externalStorage)
    public var rawHTML: String?
    
    // Markdown should be fast to access - remove external storage
    public var extractedMarkdown: String = ""
    
    // Keep large binary image data in external storage
    @Attribute(.externalStorage)
    public var images: [UUID: Data] = [:]
    
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
        rawHTML: String? = nil,
        extractedMarkdown: String,
        images: [UUID: Data] = [:],
        coverImageId: UUID? = nil,
        tags: [String] = []
    ) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.rawHTML = rawHTML
        self.extractedMarkdown = extractedMarkdown
        self.images = images
        self.coverImageId = coverImageId
        self.dateAdded = Date()
        self.dateModified = Date()
        self.tags = tags
        self.contentPreview = Self.generatePreview(from: extractedMarkdown)
    }
    
    public func updateContent(
        title: String? = nil,
        extractedMarkdown: String? = nil,
        images: [UUID: Data]? = nil,
        coverImageId: UUID? = nil,
        tags: [String]? = nil
    ) {
        if let title = title {
            self.title = title
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
        self.dateModified = Date()
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
                
                // Store in cache
                if let uuid = await imageCache.store(data: imageData, format: format) {
                    let tokenReplacement = "![" + altText + "](stower://image/\(uuid))"
                    migratedMarkdown = migratedMarkdown.replacingOccurrences(of: fullMatch, with: tokenReplacement)
                    print("✅ SavedItem: Migrated base64 image to token: \(uuid)")
                } else {
                    print("❌ SavedItem: Failed to store migrated image in cache")
                }
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

extension SavedItem {
    @MainActor
    public static let preview = SavedItem(
        url: URL(string: "https://example.com/article"),
        title: "Sample Article",
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