import Foundation
@preconcurrency import SwiftData

/// Schema version V1 - Current production schema with only SavedItem and ImageDownloadSettings
public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    
    public static var models: [any PersistentModel.Type] {
        [SavedItemV1.self, ImageDownloadSettingsV1.self]
    }
    
    @Model
    final class SavedItemV1 {
        var id: UUID = UUID()
        var url: URL?
        var title: String = ""
        var author: String = ""
        
        @Attribute(.externalStorage)
        var rawHTML: String?
        
        var extractedMarkdown: String = ""
        
        @Attribute(.externalStorage)
        var images: [UUID: Data] = [:]
        
        var imageDownloadPreference: String = "auto" // ItemImagePreference as String
        var coverImageId: UUID?
        var dateAdded: Date = Date()
        var dateModified: Date = Date()
        var tags: [String] = []
        var contentPreview: String = ""
        var lastReadChunkIndex: Int = 0
        
        init(
            url: URL? = nil,
            title: String,
            author: String = "",
            rawHTML: String? = nil,
            extractedMarkdown: String,
            images: [UUID: Data] = [:],
            coverImageId: UUID? = nil,
            tags: [String] = [],
            imageDownloadPreference: String = "auto"
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
        
        static func generatePreview(from markdown: String) -> String {
            let cleanText = markdown
                .replacingOccurrences(of: #"!\\[.*?\\]\\(.*?\\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"#{1,6}\\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\\*{1,2}(.*?)\\*{1,2}"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"`(.*?)`"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\\[(.*?)\\]\\(.*?\\)"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            let previewLength = 150
            if cleanText.count <= previewLength {
                return cleanText
            }
            
            let truncated = String(cleanText.prefix(previewLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                return String(truncated[..<lastSpace]) + "…"
            }
            
            return truncated + "…"
        }
    }
    
    @Model
    final class ImageDownloadSettingsV1 {
        var id: UUID = UUID()
        var globalAutoDownload: Bool = false
        var alwaysDownloadDomains: [String] = []
        var neverDownloadDomains: [String] = []
        var askForNewDomains: Bool = true
        var downloadStats: [String: Int] = [:]
        var lastCleanupDate: Date?
        
        init() {
            self.id = UUID()
            self.globalAutoDownload = false
            self.alwaysDownloadDomains = []
            self.neverDownloadDomains = []
            self.askForNewDomains = true
            self.downloadStats = [:]
            self.lastCleanupDate = nil
        }
    }
}

/// Schema version V2 - Adds image relationship models for CloudKit sync
public enum SchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    
    public static var models: [any PersistentModel.Type] {
        [SavedItemV2.self, ImageDownloadSettingsV2.self, SavedImageRefV2.self, SavedImageAssetV2.self]
    }
    
    @Model
    final class SavedItemV2 {
        var id: UUID = UUID()
        var url: URL?
        var title: String = ""
        var author: String = ""
        
        @Attribute(.externalStorage)
        var rawHTML: String?
        
        var extractedMarkdown: String = ""
        
        @Attribute(.externalStorage)
        var images: [UUID: Data] = [:]
        
        var imageDownloadPreference: String = "auto"
        var coverImageId: UUID?
        var dateAdded: Date = Date()
        var dateModified: Date = Date()
        var tags: [String] = []
        var contentPreview: String = ""
        var lastReadChunkIndex: Int = 0
        
        // New relationships in V2
        @Relationship(deleteRule: .cascade)
        var imageRefs: [SavedImageRefV2] = []
        
        @Relationship(deleteRule: .cascade)
        var imageAssets: [SavedImageAssetV2] = []
        
        init(
            url: URL? = nil,
            title: String,
            author: String = "",
            rawHTML: String? = nil,
            extractedMarkdown: String,
            images: [UUID: Data] = [:],
            coverImageId: UUID? = nil,
            tags: [String] = [],
            imageDownloadPreference: String = "auto"
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
            self.imageRefs = []
            self.imageAssets = []
        }
        
        static func generatePreview(from markdown: String) -> String {
            let cleanText = markdown
                .replacingOccurrences(of: #"!\\[.*?\\]\\(.*?\\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"#{1,6}\\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\\*{1,2}(.*?)\\*{1,2}"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"`(.*?)`"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\\[(.*?)\\]\\(.*?\\)"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            let previewLength = 150
            if cleanText.count <= previewLength {
                return cleanText
            }
            
            let truncated = String(cleanText.prefix(previewLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                return String(truncated[..<lastSpace]) + "…"
            }
            
            return truncated + "…"
        }
    }
    
    @Model
    final class ImageDownloadSettingsV2 {
        var id: UUID = UUID()
        var globalAutoDownload: Bool = false
        var alwaysDownloadDomains: [String] = []
        var neverDownloadDomains: [String] = []
        var askForNewDomains: Bool = true
        var downloadStats: [String: Int] = [:]
        var lastCleanupDate: Date?
        
        init() {
            self.id = UUID()
            self.globalAutoDownload = false
            self.alwaysDownloadDomains = []
            self.neverDownloadDomains = []
            self.askForNewDomains = true
            self.downloadStats = [:]
            self.lastCleanupDate = nil
        }
    }
    
    @Model
    final class SavedImageRefV2 {
        var id: UUID = UUID()
        var sourceURL: URL?
        var width: Int = 0
        var height: Int = 0
        var sha256: String = ""
        var origin: String = "web" // ImageOrigin as String
        var hasLocalFile: Bool = false
        var downloadStatus: String = "pending" // ImageDownloadStatus as String
        var fileFormat: String = "jpg"
        var createdAt: Date = Date()
        var lastDownloadAttempt: Date?
        var downloadFailureCount: Int = 0
        
        @Relationship
        var item: SavedItemV2?
        
        init(
            sourceURL: URL? = nil,
            width: Int = 0,
            height: Int = 0,
            sha256: String = "",
            origin: String = "web",
            fileFormat: String = "jpg"
        ) {
            self.id = UUID()
            self.sourceURL = sourceURL
            self.width = width
            self.height = height
            self.sha256 = sha256
            self.origin = origin
            self.fileFormat = fileFormat
            self.hasLocalFile = false
            self.downloadStatus = "pending"
            self.createdAt = Date()
            self.downloadFailureCount = 0
        }
    }
    
    @Model
    final class SavedImageAssetV2 {
        var id: UUID = UUID()
        var width: Int = 0
        var height: Int = 0
        var byteCount: Int = 0
        var origin: String = "pdf" // ImageOrigin as String
        var fileFormat: String = "jpg"
        var createdAt: Date = Date()
        var altText: String = ""
        
        @Attribute(.externalStorage)
        var imageData: Data = Data()
        
        @Relationship
        var item: SavedItemV2?
        
        init(
            imageData: Data,
            width: Int = 0,
            height: Int = 0,
            origin: String = "pdf",
            fileFormat: String = "jpg",
            altText: String = ""
        ) {
            self.id = UUID()
            self.imageData = imageData
            self.width = width
            self.height = height
            self.byteCount = imageData.count
            self.origin = origin
            self.fileFormat = fileFormat
            self.altText = altText
            self.createdAt = Date()
        }
    }
}

/// Migration plan for safe CloudKit schema evolution
public enum StowerMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }
    
    public static var stages: [MigrationStage] { [migrateV1toV2] }
    
    /// Migration from V1 to V2 - Adds image relationship models
    static var migrateV1toV2: MigrationStage {
        .lightweight(
            fromVersion: SchemaV1.self,
            toVersion: SchemaV2.self
        )
    }
}
