import Testing
import Foundation
import SwiftData
@testable import StowerFeature

@MainActor
@Suite("SavedImageAsset Tests")
struct SavedImageAssetTests {
    
    // MARK: - Initialization Tests
    
    @Test("SavedImageAsset should initialize with default values")
    func testDefaultInitialization() async throws {
        let imageData = MockImageData.minimalJPEG()
        let asset = SavedImageAsset(imageData: imageData)
        
        #expect(asset.id != UUID()) // Should have a unique ID
        #expect(asset.imageData == imageData)
        #expect(asset.width == 0) // Default when not specified
        #expect(asset.height == 0)
        #expect(asset.byteCount == imageData.count)
        #expect(asset.origin == .pdf) // Default origin
        #expect(asset.fileFormat == "jpg") // Default format
        #expect(asset.altText == "") // Default alt text
        #expect(asset.createdAt.timeIntervalSince1970 > 0)
        #expect(asset.item == nil) // No relationship by default
    }
    
    @Test("SavedImageAsset should initialize with custom values")
    func testCustomInitialization() async throws {
        let imageData = MockImageData.validPNGHeader()
        let asset = SavedImageAsset(
            imageData: imageData,
            width: 800,
            height: 600,
            origin: .web,
            fileFormat: "png",
            altText: "Test image description"
        )
        
        #expect(asset.imageData == imageData)
        #expect(asset.width == 800)
        #expect(asset.height == 600)
        #expect(asset.byteCount == imageData.count)
        #expect(asset.origin == .web)
        #expect(asset.fileFormat == "png")
        #expect(asset.altText == "Test image description")
    }
    
    // MARK: - Data Update Tests
    
    @Test("updateImageData should update data and byte count")
    func testUpdateImageData() async throws {
        let asset = SavedImageAsset(imageData: MockImageData.minimalJPEG())
        let originalByteCount = asset.byteCount
        
        let newImageData = MockImageData.validPNGHeader()
        asset.updateImageData(newImageData)
        
        #expect(asset.imageData == newImageData)
        #expect(asset.byteCount == newImageData.count)
        #expect(asset.byteCount != originalByteCount)
    }
    
    @Test("updateImageData should handle empty data")
    func testUpdateImageDataWithEmpty() async throws {
        let asset = SavedImageAsset(imageData: MockImageData.minimalJPEG())
        
        let emptyData = Data()
        asset.updateImageData(emptyData)
        
        #expect(asset.imageData == emptyData)
        #expect(asset.byteCount == 0)
    }
    
    // MARK: - Formatting Tests
    
    @Test("formattedSize should return human-readable byte count")
    func testFormattedSize() async throws {
        let smallData = Data(count: 1024) // 1 KB
        let smallAsset = SavedImageAsset(imageData: smallData)
        let smallFormatted = smallAsset.formattedSize
        #expect(smallFormatted.contains("KB") || smallFormatted.contains("kB"))
        
        let largeData = Data(count: 1_048_576) // 1 MB
        let largeAsset = SavedImageAsset(imageData: largeData)
        let largeFormatted = largeAsset.formattedSize
        #expect(largeFormatted.contains("MB"))
        
        let emptyAsset = SavedImageAsset(imageData: Data())
        let emptyFormatted = emptyAsset.formattedSize
        #expect(emptyFormatted.contains("0") || emptyFormatted.contains("bytes"))
    }
    
    @Test("dimensionsString should format dimensions correctly")
    func testDimensionsString() async throws {
        let asset = SavedImageAsset(
            imageData: MockImageData.minimalJPEG(),
            width: 1920,
            height: 1080
        )
        
        #expect(asset.dimensionsString == "1920×1080")
        
        let zeroAsset = SavedImageAsset(imageData: MockImageData.minimalJPEG())
        #expect(zeroAsset.dimensionsString == "0×0")
        
        let squareAsset = SavedImageAsset(
            imageData: MockImageData.minimalJPEG(),
            width: 500,
            height: 500
        )
        #expect(squareAsset.dimensionsString == "500×500")
    }
    
    // MARK: - Factory Method Tests
    
    @Test("create factory method should work with defaults")
    func testCreateFactoryMethodDefaults() async throws {
        let imageData = MockImageData.minimalJPEG()
        let asset = await SavedImageAsset.create(from: imageData)
        
        #expect(asset.imageData == imageData)
        #expect(asset.origin == .pdf) // Default
        #expect(asset.fileFormat == "jpg") // Default
        #expect(asset.altText == "") // Default
        #expect(asset.byteCount == imageData.count)
        // Note: Dimensions will depend on the actual image processing
    }
    
    @Test("create factory method should work with custom parameters")
    func testCreateFactoryMethodCustom() async throws {
        let imageData = MockImageData.validPNGHeader()
        let asset = await SavedImageAsset.create(
            from: imageData,
            origin: .web,
            fileFormat: "png",
            altText: "Custom alt text"
        )
        
        #expect(asset.imageData == imageData)
        #expect(asset.origin == .web)
        #expect(asset.fileFormat == "png")
        #expect(asset.altText == "Custom alt text")
    }
    
    // MARK: - SwiftData Relationship Tests
    
    @Test("SavedImageAsset should establish relationship with SavedItem")
    func testSavedItemRelationship() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let item = TestDataFactory.createSavedItem()
        let asset = SavedImageAsset(imageData: MockImageData.minimalJPEG())
        
        asset.item = item
        
        context.insert(item)
        context.insert(asset)
        try context.save()
        
        #expect(asset.item === item)
        
        // Fetch from context to verify persistence
        let fetchDescriptor = FetchDescriptor<SavedImageAsset>()
        let fetchedAssets = try context.fetch(fetchDescriptor)
        
        #expect(fetchedAssets.count == 1)
        let fetchedAsset = fetchedAssets.first!
        #expect(fetchedAsset.item?.title == item.title)
    }
    
    // MARK: - SwiftData Persistence Tests
    
    @Test("SavedImageAsset should persist all properties")
    func testSwiftDataPersistence() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let imageData = MockImageData.minimalJPEG()
        let asset = SavedImageAsset(
            imageData: imageData,
            width: 800,
            height: 600,
            origin: .web,
            fileFormat: "jpg",
            altText: "Persisted image"
        )
        
        context.insert(asset)
        try context.save()
        
        let fetchDescriptor = FetchDescriptor<SavedImageAsset>()
        let fetchedAssets = try context.fetch(fetchDescriptor)
        
        #expect(fetchedAssets.count == 1)
        let retrieved = fetchedAssets.first!
        
        #expect(retrieved.imageData == imageData)
        #expect(retrieved.width == 800)
        #expect(retrieved.height == 600)
        #expect(retrieved.byteCount == imageData.count)
        #expect(retrieved.origin == .web)
        #expect(retrieved.fileFormat == "jpg")
        #expect(retrieved.altText == "Persisted image")
    }
    
    @Test("SavedImageAsset should handle large image data with external storage")
    func testLargeImageDataHandling() async throws {
        let context = try ModelContext.inMemoryContext()
        
        // Create large image data (5MB)
        let largeImageData = Data(count: 5_000_000)
        let asset = SavedImageAsset(
            imageData: largeImageData,
            width: 4000,
            height: 3000,
            origin: .web,
            fileFormat: "jpg"
        )
        
        context.insert(asset)
        try context.save()
        
        let fetchDescriptor = FetchDescriptor<SavedImageAsset>()
        let fetchedAssets = try context.fetch(fetchDescriptor)
        
        #expect(fetchedAssets.count == 1)
        let retrieved = fetchedAssets.first!
        
        #expect(retrieved.imageData.count == 5_000_000)
        #expect(retrieved.byteCount == 5_000_000)
        #expect(retrieved.formattedSize.contains("MB"))
    }
    
    // MARK: - Edge Cases and Error Handling
    
    @Test("SavedImageAsset should handle empty image data")
    func testEmptyImageData() async throws {
        let emptyData = Data()
        let asset = SavedImageAsset(imageData: emptyData)
        
        #expect(asset.imageData == emptyData)
        #expect(asset.byteCount == 0)
        #expect(asset.formattedSize.contains("0"))
    }
    
    @Test("SavedImageAsset should handle malformed image data")
    func testMalformedImageData() async throws {
        let malformedData = MockImageData.invalidImageData()
        let asset = await SavedImageAsset.create(from: malformedData)
        
        #expect(asset.imageData == malformedData)
        #expect(asset.byteCount == malformedData.count)
        // Dimensions should be 0 when image processing fails
        #expect(asset.width == 0)
        #expect(asset.height == 0)
    }
    
    @Test("SavedImageAsset should handle very large dimensions")
    func testVeryLargeDimensions() async throws {
        let asset = SavedImageAsset(
            imageData: MockImageData.minimalJPEG(),
            width: 100_000,
            height: 50_000
        )
        
        #expect(asset.width == 100_000)
        #expect(asset.height == 50_000)
        #expect(asset.dimensionsString == "100000×50000")
    }
    
    // MARK: - Performance Tests
    
    @Test("SavedImageAsset operations should be performant", .timeLimit(.minutes(1)))
    func testPerformance() async throws {
        let imageData = MockImageData.minimalJPEG()
        
        let (_, creationDuration) = await PerformanceTestUtils.measure {
            return SavedImageAsset(imageData: imageData, width: 800, height: 600)
        }
        
        #expect(creationDuration < 0.1, "Asset creation should be fast")
        
        let asset = SavedImageAsset(imageData: imageData)
        let largeData = Data(count: 1_000_000) // 1MB
        
        let (_, updateDuration) = await PerformanceTestUtils.measure { @MainActor in
            asset.updateImageData(largeData)
        }
        
        #expect(updateDuration < 0.5, "Data update should complete within reasonable time")
    }
    
    // MARK: - Multiple Assets Tests
    
    @Test("Multiple SavedImageAssets should maintain independence")
    func testMultipleAssetsIndependence() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let asset1 = SavedImageAsset(
            imageData: MockImageData.minimalJPEG(),
            width: 800,
            height: 600,
            fileFormat: "jpg"
        )
        
        let asset2 = SavedImageAsset(
            imageData: MockImageData.validPNGHeader(),
            width: 1024,
            height: 768,
            fileFormat: "png"
        )
        
        context.insert(asset1)
        context.insert(asset2)
        try context.save()
        
        // Verify they have different IDs
        #expect(asset1.id != asset2.id)
        
        // Verify independent properties
        #expect(asset1.fileFormat == "jpg")
        #expect(asset2.fileFormat == "png")
        #expect(asset1.width == 800)
        #expect(asset2.width == 1024)
        
        // Update one asset should not affect the other
        asset1.updateImageData(Data(count: 500))
        #expect(asset1.byteCount == 500)
        #expect(asset2.byteCount != 500)
    }
    
    // MARK: - Alt Text Tests
    
    @Test("SavedImageAsset should handle various alt text scenarios")
    func testAltTextHandling() async throws {
        // Empty alt text
        let emptyAltAsset = SavedImageAsset(imageData: MockImageData.minimalJPEG())
        #expect(emptyAltAsset.altText == "")
        
        // Normal alt text
        let normalAltAsset = SavedImageAsset(
            imageData: MockImageData.minimalJPEG(),
            altText: "A beautiful landscape photo"
        )
        #expect(normalAltAsset.altText == "A beautiful landscape photo")
        
        // Very long alt text
        let longAltText = String(repeating: "Very long description. ", count: 100)
        let longAltAsset = SavedImageAsset(
            imageData: MockImageData.minimalJPEG(),
            altText: longAltText
        )
        #expect(longAltAsset.altText == longAltText)
        
        // Special characters in alt text
        let specialAltAsset = SavedImageAsset(
            imageData: MockImageData.minimalJPEG(),
            altText: "Image with special chars: éñ中文🖼️"
        )
        #expect(specialAltAsset.altText == "Image with special chars: éñ中文🖼️")
    }
}

// MARK: - ImageOrigin Enum Tests

@Suite("ImageOrigin Tests")
struct ImageOriginTests {
    
    @Test("ImageOrigin should have correct display names")
    func testImageOriginDisplayNames() async throws {
        #expect(ImageOrigin.web.displayName == "Web")
        #expect(ImageOrigin.pdf.displayName == "PDF")
        #expect(ImageOrigin.pasted.displayName == "Pasted")
        #expect(ImageOrigin.migrated.displayName == "Migrated")
    }
    
    @Test("ImageOrigin should be Codable")
    func testImageOriginCodable() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for origin in ImageOrigin.allCases {
            let encoded = try encoder.encode(origin)
            let decoded = try decoder.decode(ImageOrigin.self, from: encoded)
            #expect(decoded == origin)
        }
    }
    
    @Test("ImageOrigin should have all expected cases")
    func testImageOriginAllCases() async throws {
        let allCases = ImageOrigin.allCases
        #expect(allCases.count == 4)
        #expect(allCases.contains(.web))
        #expect(allCases.contains(.pdf))
        #expect(allCases.contains(.pasted))
        #expect(allCases.contains(.migrated))
    }
    
    @Test("ImageOrigin should handle raw values correctly")
    func testImageOriginRawValues() async throws {
        #expect(ImageOrigin.web.rawValue == "web")
        #expect(ImageOrigin.pdf.rawValue == "pdf")
        #expect(ImageOrigin.pasted.rawValue == "pasted")
        #expect(ImageOrigin.migrated.rawValue == "migrated")
        
        // Test reverse lookup
        #expect(ImageOrigin(rawValue: "web") == .web)
        #expect(ImageOrigin(rawValue: "pdf") == .pdf)
        #expect(ImageOrigin(rawValue: "pasted") == .pasted)
        #expect(ImageOrigin(rawValue: "migrated") == .migrated)
        #expect(ImageOrigin(rawValue: "invalid") == nil)
    }
}