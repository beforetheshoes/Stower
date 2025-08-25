import Testing
import Foundation
import SwiftData
@testable import StowerFeature

@MainActor
@Suite("StowerMigrationPlan Tests")
struct StowerMigrationPlanTests {
    
    // MARK: - Schema Version Tests
    
    @Test("SchemaV1 should have correct version identifier")
    func testSchemaV1Version() async throws {
        let version = SchemaV1.versionIdentifier
        #expect(version.major == 1)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
    }
    
    @Test("SchemaV2 should have correct version identifier")  
    func testSchemaV2Version() async throws {
        let version = SchemaV2.versionIdentifier
        #expect(version.major == 2)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
    }
    
    @Test("SchemaV1 should have correct models")
    func testSchemaV1Models() async throws {
        let models = SchemaV1.models
        #expect(models.count == 2)
        
        let modelNames = models.map { String(describing: $0) }
        #expect(modelNames.contains("SavedItemV1"))
        #expect(modelNames.contains("ImageDownloadSettingsV1"))
    }
    
    @Test("SchemaV2 should have correct models")
    func testSchemaV2Models() async throws {
        let models = SchemaV2.models
        #expect(models.count == 4)
        
        let modelNames = models.map { String(describing: $0) }
        #expect(modelNames.contains("SavedItemV2"))
        #expect(modelNames.contains("ImageDownloadSettingsV2"))
        #expect(modelNames.contains("SavedImageRefV2"))
        #expect(modelNames.contains("SavedImageAssetV2"))
    }
    
    @Test("StowerMigrationPlan should have correct schemas")
    func testMigrationPlanSchemas() async throws {
        let schemas = StowerMigrationPlan.schemas
        #expect(schemas.count == 2)
        
        let schemaNames = schemas.map { String(describing: $0) }
        #expect(schemaNames.contains("SchemaV1"))
        #expect(schemaNames.contains("SchemaV2"))
    }
    
    @Test("StowerMigrationPlan should have correct stages")
    func testMigrationPlanStages() async throws {
        let stages = StowerMigrationPlan.stages
        #expect(stages.count == 1)
        
        // The stage should be a lightweight migration from V1 to V2
        // We can't easily test the internals, but we can verify it exists
        #expect(!stages.isEmpty)
    }
    
    // MARK: - SavedItemV1 Tests
    
    @Test("SavedItemV1 should initialize with correct defaults")
    func testSavedItemV1Initialization() async throws {
        let item = SchemaV1.SavedItemV1(
            title: "Test Title",
            extractedMarkdown: "# Test Markdown\n\nContent here."
        )
        
        #expect(item.id != UUID())
        #expect(item.title == "Test Title")
        #expect(item.author == "")
        #expect(item.extractedMarkdown == "# Test Markdown\n\nContent here.")
        #expect(item.images.isEmpty)
        #expect(item.imageDownloadPreference == "auto")
        #expect(item.tags.isEmpty)
        #expect(item.lastReadChunkIndex == 0)
        #expect(item.dateAdded.timeIntervalSince1970 > 0)
        #expect(item.dateModified.timeIntervalSince1970 > 0)
        #expect(!item.contentPreview.isEmpty)
    }
    
    @Test("SavedItemV1 should initialize with custom values")
    func testSavedItemV1CustomInitialization() async throws {
        let url = URL(string: "https://example.com/article")!
        let testImages = [UUID(): Data("image1".utf8), UUID(): Data("image2".utf8)]
        let coverImageId = UUID()
        
        let item = SchemaV1.SavedItemV1(
            url: url,
            title: "Custom Title",
            author: "Test Author",
            rawHTML: "<p>Raw HTML content</p>",
            extractedMarkdown: "# Custom Markdown",
            images: testImages,
            coverImageId: coverImageId,
            tags: ["tag1", "tag2"],
            imageDownloadPreference: "manual"
        )
        
        #expect(item.url == url)
        #expect(item.title == "Custom Title")
        #expect(item.author == "Test Author")
        #expect(item.rawHTML == "<p>Raw HTML content</p>")
        #expect(item.extractedMarkdown == "# Custom Markdown")
        #expect(item.images.count == 2)
        #expect(item.coverImageId == coverImageId)
        #expect(item.tags == ["tag1", "tag2"])
        #expect(item.imageDownloadPreference == "manual")
    }
    
    @Test("SavedItemV1 generatePreview should strip markdown formatting")
    func testSavedItemV1PreviewGeneration() async throws {
        let markdownContent = """
        # Main Title
        
        This is a paragraph with **bold text** and *italic text*.
        
        Here's some `inline code` and a [link](https://example.com).
        
        ![Image description](https://example.com/image.jpg)
        
        ## Second Header
        
        More content here.
        """
        
        let preview = SchemaV1.SavedItemV1.generatePreview(from: markdownContent)
        
        // Should strip headers
        #expect(!preview.contains("#"))
        
        // Should strip formatting
        #expect(!preview.contains("**"))
        #expect(!preview.contains("*"))
        #expect(!preview.contains("`"))
        
        // Should strip links
        #expect(!preview.contains("["))
        #expect(!preview.contains("]("))
        
        // Should strip images
        #expect(!preview.contains("!["))
        
        // Should contain plain text
        #expect(preview.contains("This is a paragraph"))
        #expect(preview.contains("bold text"))
        #expect(preview.contains("italic text"))
    }
    
    @Test("SavedItemV1 generatePreview should truncate long content")
    func testSavedItemV1PreviewTruncation() async throws {
        let longContent = String(repeating: "This is a very long sentence. ", count: 20)
        let preview = SchemaV1.SavedItemV1.generatePreview(from: longContent)
        
        #expect(preview.count <= 151) // 150 + 1 for ellipsis
        #expect(preview.hasSuffix("…"))
        
        // Should truncate at word boundary when possible
        let words = preview.dropLast().components(separatedBy: " ")
        let lastWord = words.last ?? ""
        #expect(!lastWord.contains("This"))  // Should not cut off mid-word
    }
    
    @Test("SavedItemV1 generatePreview should handle short content")
    func testSavedItemV1PreviewShortContent() async throws {
        let shortContent = "This is short content."
        let preview = SchemaV1.SavedItemV1.generatePreview(from: shortContent)
        
        #expect(preview == shortContent)
        #expect(!preview.contains("…"))
    }
    
    // MARK: - ImageDownloadSettingsV1 Tests
    
    @Test("ImageDownloadSettingsV1 should initialize with correct defaults")
    func testImageDownloadSettingsV1Initialization() async throws {
        let settings = SchemaV1.ImageDownloadSettingsV1()
        
        #expect(settings.id != UUID())
        #expect(settings.globalAutoDownload == false)  // Note: Different from current version
        #expect(settings.alwaysDownloadDomains.isEmpty)
        #expect(settings.neverDownloadDomains.isEmpty)
        #expect(settings.askForNewDomains == true)  // Different from current version
        #expect(settings.downloadStats.isEmpty)
        #expect(settings.lastCleanupDate == nil)
    }
    
    // MARK: - SavedItemV2 Tests
    
    @Test("SavedItemV2 should initialize with relationships")
    func testSavedItemV2Relationships() async throws {
        let item = SchemaV2.SavedItemV2(
            title: "Test Title V2",
            extractedMarkdown: "# Test Content"
        )
        
        #expect(item.title == "Test Title V2")
        #expect(item.imageRefs.isEmpty)
        #expect(item.imageAssets.isEmpty)
        
        // All other properties should work the same as V1
        #expect(item.imageDownloadPreference == "auto")
        #expect(item.tags.isEmpty)
        #expect(!item.contentPreview.isEmpty)
    }
    
    @Test("SavedItemV2 should maintain same preview generation as V1")
    func testSavedItemV2PreviewGeneration() async throws {
        let markdownContent = "# Title\n\nContent with **bold** text."
        
        let previewV1 = SchemaV1.SavedItemV1.generatePreview(from: markdownContent)
        let previewV2 = SchemaV2.SavedItemV2.generatePreview(from: markdownContent)
        
        #expect(previewV1 == previewV2)
    }
    
    // MARK: - SavedImageRefV2 Tests
    
    @Test("SavedImageRefV2 should initialize with correct defaults")
    func testSavedImageRefV2Initialization() async throws {
        let imageRef = SchemaV2.SavedImageRefV2()
        
        #expect(imageRef.id != UUID())
        #expect(imageRef.sourceURL == nil)
        #expect(imageRef.width == 0)
        #expect(imageRef.height == 0)
        #expect(imageRef.sha256 == "")
        #expect(imageRef.origin == "web")
        #expect(imageRef.hasLocalFile == false)
        #expect(imageRef.downloadStatus == "pending")
        #expect(imageRef.fileFormat == "jpg")
        #expect(imageRef.createdAt.timeIntervalSince1970 > 0)
        #expect(imageRef.lastDownloadAttempt == nil)
        #expect(imageRef.downloadFailureCount == 0)
        #expect(imageRef.item == nil)
    }
    
    @Test("SavedImageRefV2 should initialize with custom values")
    func testSavedImageRefV2CustomInitialization() async throws {
        let url = URL(string: "https://example.com/image.jpg")!
        
        let imageRef = SchemaV2.SavedImageRefV2(
            sourceURL: url,
            width: 800,
            height: 600,
            sha256: "test_hash",
            origin: "pdf",
            fileFormat: "png"
        )
        
        #expect(imageRef.sourceURL == url)
        #expect(imageRef.width == 800)
        #expect(imageRef.height == 600)
        #expect(imageRef.sha256 == "test_hash")
        #expect(imageRef.origin == "pdf")
        #expect(imageRef.fileFormat == "png")
        #expect(imageRef.downloadStatus == "pending")
    }
    
    // MARK: - SavedImageAssetV2 Tests
    
    @Test("SavedImageAssetV2 should initialize with correct defaults")
    func testSavedImageAssetV2Initialization() async throws {
        let imageData = MockImageData.minimalJPEG()
        let asset = SchemaV2.SavedImageAssetV2(imageData: imageData)
        
        #expect(asset.id != UUID())
        #expect(asset.imageData == imageData)
        #expect(asset.width == 0)
        #expect(asset.height == 0)
        #expect(asset.byteCount == imageData.count)
        #expect(asset.origin == "pdf")
        #expect(asset.fileFormat == "jpg")
        #expect(asset.altText == "")
        #expect(asset.createdAt.timeIntervalSince1970 > 0)
        #expect(asset.item == nil)
    }
    
    @Test("SavedImageAssetV2 should initialize with custom values")
    func testSavedImageAssetV2CustomInitialization() async throws {
        let imageData = MockImageData.validPNGHeader()
        
        let asset = SchemaV2.SavedImageAssetV2(
            imageData: imageData,
            width: 1024,
            height: 768,
            origin: "web",
            fileFormat: "png",
            altText: "Test image"
        )
        
        #expect(asset.imageData == imageData)
        #expect(asset.width == 1024)
        #expect(asset.height == 768)
        #expect(asset.byteCount == imageData.count)
        #expect(asset.origin == "web")
        #expect(asset.fileFormat == "png")
        #expect(asset.altText == "Test image")
    }
    
    // MARK: - Schema Persistence Tests
    
    @Test("SchemaV1 models should persist correctly")
    func testSchemaV1Persistence() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        
        let item = SchemaV1.SavedItemV1(
            title: "V1 Test Item",
            extractedMarkdown: "Test content"
        )
        
        let settings = SchemaV1.ImageDownloadSettingsV1()
        settings.globalAutoDownload = true
        settings.alwaysDownloadDomains = ["test.com"]
        
        context.insert(item)
        context.insert(settings)
        try context.save()
        
        // Fetch items
        let itemDescriptor = FetchDescriptor<SchemaV1.SavedItemV1>()
        let fetchedItems = try context.fetch(itemDescriptor)
        
        let settingsDescriptor = FetchDescriptor<SchemaV1.ImageDownloadSettingsV1>()
        let fetchedSettings = try context.fetch(settingsDescriptor)
        
        #expect(fetchedItems.count == 1)
        #expect(fetchedItems.first?.title == "V1 Test Item")
        
        #expect(fetchedSettings.count == 1)
        #expect(fetchedSettings.first?.globalAutoDownload == true)
        #expect(fetchedSettings.first?.alwaysDownloadDomains == ["test.com"])
    }
    
    @Test("SchemaV2 models should persist with relationships")
    func testSchemaV2Persistence() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let schema = Schema(SchemaV2.models)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        
        let item = SchemaV2.SavedItemV2(
            title: "V2 Test Item",
            extractedMarkdown: "Test content"
        )
        
        let imageRef = SchemaV2.SavedImageRefV2(
            sourceURL: URL(string: "https://example.com/image.jpg"),
            width: 800,
            height: 600
        )
        
        let imageAsset = SchemaV2.SavedImageAssetV2(
            imageData: MockImageData.minimalJPEG(),
            width: 400,
            height: 300
        )
        
        // Establish relationships
        imageRef.item = item
        imageAsset.item = item
        item.imageRefs.append(imageRef)
        item.imageAssets.append(imageAsset)
        
        context.insert(item)
        context.insert(imageRef)
        context.insert(imageAsset)
        try context.save()
        
        // Fetch and verify relationships
        let itemDescriptor = FetchDescriptor<SchemaV2.SavedItemV2>()
        let fetchedItems = try context.fetch(itemDescriptor)
        
        #expect(fetchedItems.count == 1)
        let fetchedItem = fetchedItems.first!
        
        #expect(fetchedItem.title == "V2 Test Item")
        #expect(fetchedItem.imageRefs.count == 1)
        #expect(fetchedItem.imageAssets.count == 1)
        #expect(fetchedItem.imageRefs.first?.width == 800)
        #expect(fetchedItem.imageAssets.first?.width == 400)
    }
    
    // MARK: - Migration Compatibility Tests
    
    @Test("Schema versions should be ordered correctly")
    func testSchemaVersionOrdering() async throws {
        let v1 = SchemaV1.versionIdentifier
        let v2 = SchemaV2.versionIdentifier
        
        #expect(v1 < v2)
        #expect(v1.major < v2.major)
    }
    
    @Test("V1 and V2 SavedItem models should have compatible core fields")
    func testSavedItemCompatibility() async throws {
        // Both versions should have the same core properties for migration compatibility
        let markdownContent = "# Test\n\nContent"
        
        let itemV1 = SchemaV1.SavedItemV1(
            title: "Test Title",
            author: "Test Author",
            extractedMarkdown: markdownContent,
            tags: ["tag1", "tag2"]
        )
        
        let itemV2 = SchemaV2.SavedItemV2(
            title: "Test Title",
            author: "Test Author",
            extractedMarkdown: markdownContent,
            tags: ["tag1", "tag2"]
        )
        
        // Core fields should be equivalent
        #expect(itemV1.title == itemV2.title)
        #expect(itemV1.author == itemV2.author)
        #expect(itemV1.extractedMarkdown == itemV2.extractedMarkdown)
        #expect(itemV1.tags == itemV2.tags)
        #expect(itemV1.imageDownloadPreference == itemV2.imageDownloadPreference)
        #expect(itemV1.contentPreview == itemV2.contentPreview)
    }
    
    @Test("V1 and V2 ImageDownloadSettings should have compatible core fields")
    func testImageDownloadSettingsCompatibility() async throws {
        let settingsV1 = SchemaV1.ImageDownloadSettingsV1()
        settingsV1.globalAutoDownload = true
        settingsV1.alwaysDownloadDomains = ["example.com"]
        settingsV1.askForNewDomains = false
        
        let settingsV2 = SchemaV2.ImageDownloadSettingsV2()
        settingsV2.globalAutoDownload = true
        settingsV2.alwaysDownloadDomains = ["example.com"]
        settingsV2.askForNewDomains = false
        
        // Core fields should be equivalent
        #expect(settingsV1.globalAutoDownload == settingsV2.globalAutoDownload)
        #expect(settingsV1.alwaysDownloadDomains == settingsV2.alwaysDownloadDomains)
        #expect(settingsV1.neverDownloadDomains == settingsV2.neverDownloadDomains)
        #expect(settingsV1.askForNewDomains == settingsV2.askForNewDomains)
    }
    
    // MARK: - Edge Cases and Error Handling
    
    @Test("Schema models should handle empty or nil values gracefully")
    func testSchemaModelsEmptyValues() async throws {
        // V1 models
        let itemV1 = SchemaV1.SavedItemV1(
            title: "",
            extractedMarkdown: ""
        )
        
        #expect(itemV1.title == "")
        #expect(itemV1.contentPreview == "") // Empty markdown should generate empty preview
        
        // V2 models  
        let itemV2 = SchemaV2.SavedItemV2(
            title: "",
            extractedMarkdown: ""
        )
        
        #expect(itemV2.title == "")
        #expect(itemV2.imageRefs.isEmpty)
        #expect(itemV2.imageAssets.isEmpty)
        
        let imageRefV2 = SchemaV2.SavedImageRefV2(sourceURL: nil)
        #expect(imageRefV2.sourceURL == nil)
        #expect(imageRefV2.sha256 == "")
        
        let emptyImageAssetV2 = SchemaV2.SavedImageAssetV2(imageData: Data())
        #expect(emptyImageAssetV2.imageData.isEmpty)
        #expect(emptyImageAssetV2.byteCount == 0)
    }
    
    @Test("Preview generation should handle markdown edge cases")
    func testPreviewGenerationEdgeCases() async throws {
        let edgeCases = [
            ("", ""), // Empty
            ("   \n\t  ", ""), // Whitespace only
            ("![]()", ""), // Empty image
            ("[]()", ""), // Empty link
            ("**bold** *italic* `code`", "bold italic code"), // Multiple formatting
            ("# Header only", "Header only"), // Header only
            ("No markdown here", "No markdown here"), // Plain text
        ]
        
        for (input, expected) in edgeCases {
            let previewV1 = SchemaV1.SavedItemV1.generatePreview(from: input)
            let previewV2 = SchemaV2.SavedItemV2.generatePreview(from: input)
            
            #expect(previewV1 == expected, "V1 preview failed for: '\(input)'")
            #expect(previewV2 == expected, "V2 preview failed for: '\(input)'")
            #expect(previewV1 == previewV2, "V1 and V2 previews differ for: '\(input)'")
        }
    }
}