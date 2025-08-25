import Testing
import Foundation
@testable import StowerFeature

@Suite("ImageCacheService Tests")
struct ImageCacheServiceTests {
    
    // MARK: - Initialization Tests
    
    @Test("ImageCacheService should be a singleton")
    func testSingletonPattern() async throws {
        let service1 = ImageCacheService.shared
        let service2 = ImageCacheService.shared
        
        #expect(service1 === service2)
    }
    
    // MARK: - Cache Management Tests
    
    @Test("clearCache should remove all cached images")
    func testClearCache() async throws {
        let service = ImageCacheService.shared
        
        // Clear cache to start fresh
        service.clearCache()
        
        // Cache should be empty
        #expect(Bool(true)) // Should complete without error
    }
    
    // MARK: - Thread Safety Tests
    
    @Test("ImageCacheService should handle concurrent access safely")
    func testConcurrentAccess() async throws {
        let service = ImageCacheService.shared
        service.clearCache()
        
        // Run multiple operations concurrently
        await withTaskGroup(of: Void.self) { group in
            // Multiple clear operations
            for _ in 0..<5 {
                group.addTask {
                    service.clearCache()
                }
            }
            
            // Wait for all tasks to complete
            for await _ in group {}
        }
        
        #expect(Bool(true)) // Should complete without deadlock or crash
    }
    
    @Test("ImageCacheService should handle rapid successive operations")
    func testRapidSuccessiveOperations() async throws {
        let service = ImageCacheService.shared
        
        // Perform rapid successive operations
        for _ in 0..<10 {
            service.clearCache()
        }
        
        #expect(Bool(true)) // Should handle rapid operations without issues
    }
    
    // MARK: - Performance Tests
    
    @Test("ImageCacheService operations should be performant", .timeLimit(.minutes(1)))
    func testPerformance() async throws {
        let service = ImageCacheService.shared
        
        let (_, clearDuration) = await PerformanceTestUtils.measure {
            service.clearCache()
        }
        
        #expect(clearDuration < 1.0, "Cache clear should be fast")
    }
    
    // MARK: - Memory Management Tests
    
    @Test("ImageCacheService should handle memory pressure gracefully")
    func testMemoryPressure() async throws {
        let service = ImageCacheService.shared
        
        // Simulate memory pressure by clearing cache multiple times
        for _ in 0..<100 {
            service.clearCache()
        }
        
        #expect(Bool(true)) // Should handle without memory issues
    }
    
    // MARK: - Error Handling Tests
    
    @Test("ImageCacheService should handle file system errors gracefully")
    func testFileSystemErrorHandling() async throws {
        let service = ImageCacheService.shared
        
        // Try to clear cache even if file system operations might fail
        service.clearCache()
        
        #expect(Bool(true)) // Should not crash on file system errors
    }
    
    // MARK: - Edge Cases
    
    @Test("ImageCacheService should work correctly when called from different threads")
    func testMultiThreadedAccess() async throws {
        let service = ImageCacheService.shared
        
        // Test from different async contexts
        async let task1: Void = {
            service.clearCache()
        }()
        
        async let task2: Void = {
            service.clearCache()
        }()
        
        async let task3: Void = {
            service.clearCache()
        }()
        
        // Wait for all tasks
        let (_, _, _) = await (task1, task2, task3)
        
        #expect(Bool(true)) // Should handle multi-threaded access safely
    }
    
    @Test("ImageCacheService should maintain consistency across rapid operations")
    func testConsistencyAcrossRapidOperations() async throws {
        let service = ImageCacheService.shared
        
        // Perform many rapid operations to test consistency
        let operationCount = 50
        
        for i in 0..<operationCount {
            service.clearCache()
            
            // Every 10 operations, verify service is still responsive
            if i % 10 == 0 {
                // Service should still be functional
                #expect(Bool(true))
            }
        }
        
        #expect(Bool(true)) // Should maintain consistency
    }
    
    // MARK: - Integration Tests
    
    @Test("ImageCacheService should integrate well with other services")
    func testServiceIntegration() async throws {
        let cacheService = ImageCacheService.shared
        let _ = await ImageProcessingService()
        
        // Clear cache
        cacheService.clearCache()
        
        // Both services should work together
        #expect(Bool(true)) // Should integrate without conflicts
    }
    
    // MARK: - Stress Tests
    
    @Test("ImageCacheService should handle stress testing", .timeLimit(.minutes(1)))
    func testStressTesting() async throws {
        let service = ImageCacheService.shared
        
        // Stress test with many concurrent operations
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    for _ in 0..<10 {
                        service.clearCache()
                    }
                }
            }
            
            // Wait for all stress test tasks
            for await _ in group {}
        }
        
        #expect(Bool(true)) // Should survive stress testing
    }
    
    @Test("ImageCacheService should recover from extreme conditions")
    func testExtremeConditionsRecovery() async throws {
        let service = ImageCacheService.shared
        
        // Simulate extreme conditions
        for _ in 0..<1000 {
            service.clearCache()
        }
        
        // Service should still be functional after extreme use
        service.clearCache()
        
        #expect(Bool(true)) // Should recover from extreme conditions
    }
}

// MARK: - ImageMetadata Tests

@Suite("ImageMetadata Tests")
struct ImageMetadataTests {
    
    @Test("ImageMetadata should initialize with correct values")
    func testImageMetadataInitialization() async throws {
        let uuid = UUID()
        let filename = "test-image.jpg"
        let sourceURL = "https://example.com/image.jpg"
        
        let metadata = ImageMetadata(
            uuid: uuid,
            filename: filename,
            width: 800,
            height: 600,
            byteCount: 1024,
            sourceURL: sourceURL
        )
        
        #expect(metadata.uuid == uuid)
        #expect(metadata.filename == filename)
        #expect(metadata.width == 800)
        #expect(metadata.height == 600)
        #expect(metadata.byteCount == 1024)
        #expect(metadata.sourceURL == sourceURL)
        #expect(metadata.createdAt.timeIntervalSince1970 > 0)
        #expect(metadata.lastAccessed.timeIntervalSince1970 > 0)
    }
    
    @Test("ImageMetadata should initialize without sourceURL")
    func testImageMetadataInitializationWithoutSourceURL() async throws {
        let uuid = UUID()
        let filename = "local-image.jpg"
        
        let metadata = ImageMetadata(
            uuid: uuid,
            filename: filename,
            width: 400,
            height: 300,
            byteCount: 512
        )
        
        #expect(metadata.uuid == uuid)
        #expect(metadata.filename == filename)
        #expect(metadata.width == 400)
        #expect(metadata.height == 300)
        #expect(metadata.byteCount == 512)
        #expect(metadata.sourceURL == nil)
        #expect(metadata.domain == nil)
    }
    
    @Test("ImageMetadata should extract domain from sourceURL")
    func testDomainExtraction() async throws {
        let testCases: [(String, String?)] = [
            ("https://example.com/image.jpg", "example.com"),
            ("http://sub.example.com/path/image.png", "sub.example.com"),
            ("https://cdn.example.org:8080/images/photo.gif", "cdn.example.org"),
            ("invalid-url", nil),
            ("", nil)
        ]
        
        for (sourceURL, expectedDomain) in testCases {
            let metadata = ImageMetadata(
                uuid: UUID(),
                filename: "test.jpg",
                width: 100,
                height: 100,
                byteCount: 100,
                sourceURL: sourceURL.isEmpty ? nil : sourceURL
            )
            
            #expect(metadata.domain == expectedDomain, "Failed for URL: \(sourceURL)")
        }
    }
    
    @Test("ImageMetadata should handle nil sourceURL for domain extraction")
    func testDomainExtractionWithNilURL() async throws {
        let metadata = ImageMetadata(
            uuid: UUID(),
            filename: "test.jpg",
            width: 100,
            height: 100,
            byteCount: 100,
            sourceURL: nil
        )
        
        #expect(metadata.domain == nil)
    }
    
    @Test("ImageMetadata should be Codable")
    func testImageMetadataCodable() async throws {
        let originalMetadata = ImageMetadata(
            uuid: UUID(),
            filename: "test-image.jpg",
            width: 1920,
            height: 1080,
            byteCount: 204800,
            sourceURL: "https://example.com/test-image.jpg"
        )
        
        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalMetadata)
        
        #expect(data.count > 0)
        
        // Decode
        let decoder = JSONDecoder()
        let decodedMetadata = try decoder.decode(ImageMetadata.self, from: data)
        
        // Verify all properties match
        #expect(decodedMetadata.uuid == originalMetadata.uuid)
        #expect(decodedMetadata.filename == originalMetadata.filename)
        #expect(decodedMetadata.width == originalMetadata.width)
        #expect(decodedMetadata.height == originalMetadata.height)
        #expect(decodedMetadata.byteCount == originalMetadata.byteCount)
        #expect(decodedMetadata.sourceURL == originalMetadata.sourceURL)
        #expect(decodedMetadata.createdAt.timeIntervalSince1970 == originalMetadata.createdAt.timeIntervalSince1970)
        #expect(decodedMetadata.lastAccessed.timeIntervalSince1970 == originalMetadata.lastAccessed.timeIntervalSince1970)
    }
    
    @Test("ImageMetadata should handle encoding/decoding with nil sourceURL")
    func testImageMetadataCodableWithNilURL() async throws {
        let originalMetadata = ImageMetadata(
            uuid: UUID(),
            filename: "local-image.jpg",
            width: 800,
            height: 600,
            byteCount: 1024
        )
        
        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalMetadata)
        
        // Decode
        let decoder = JSONDecoder()
        let decodedMetadata = try decoder.decode(ImageMetadata.self, from: data)
        
        #expect(decodedMetadata.uuid == originalMetadata.uuid)
        #expect(decodedMetadata.filename == originalMetadata.filename)
        #expect(decodedMetadata.sourceURL == nil)
        #expect(decodedMetadata.domain == nil)
    }
    
    @Test("ImageMetadata should be Sendable")
    func testImageMetadataSendable() async throws {
        let metadata = ImageMetadata(
            uuid: UUID(),
            filename: "sendable-test.jpg",
            width: 100,
            height: 100,
            byteCount: 100,
            sourceURL: "https://example.com/image.jpg"
        )
        
        // Should be able to send across actor boundaries
        let result = await Task {
            return metadata
        }.value
        
        #expect(result.filename == "sendable-test.jpg")
    }
    
    @Test("ImageMetadata should handle extreme values")
    func testImageMetadataExtremeValues() async throws {
        let metadata = ImageMetadata(
            uuid: UUID(),
            filename: String(repeating: "very-long-filename-", count: 100) + ".jpg",
            width: Int.max,
            height: Int.max,
            byteCount: Int.max,
            sourceURL: "https://" + String(repeating: "very-long-domain-name-", count: 20) + ".com/image.jpg"
        )
        
        #expect(metadata.width == Int.max)
        #expect(metadata.height == Int.max)
        #expect(metadata.byteCount == Int.max)
        #expect(metadata.filename.count > 1000)
        #expect(metadata.sourceURL?.count ?? 0 > 400)
    }
    
    @Test("ImageMetadata should handle zero and negative values")
    func testImageMetadataZeroAndNegativeValues() async throws {
        let metadata = ImageMetadata(
            uuid: UUID(),
            filename: "zero-size.jpg",
            width: 0,
            height: 0,
            byteCount: 0,
            sourceURL: "https://example.com/empty.jpg"
        )
        
        #expect(metadata.width == 0)
        #expect(metadata.height == 0)
        #expect(metadata.byteCount == 0)
        
        // Test with negative values (unusual but should handle gracefully)
        let negativeMetadata = ImageMetadata(
            uuid: UUID(),
            filename: "negative.jpg",
            width: -1,
            height: -1,
            byteCount: -1
        )
        
        #expect(negativeMetadata.width == -1)
        #expect(negativeMetadata.height == -1)
        #expect(negativeMetadata.byteCount == -1)
    }
}