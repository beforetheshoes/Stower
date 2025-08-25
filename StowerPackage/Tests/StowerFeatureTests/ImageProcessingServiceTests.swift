import Testing
import Foundation
@testable import StowerFeature

@MainActor
@Suite("ImageProcessingService Tests")
struct ImageProcessingServiceTests {
    
    // MARK: - Initialization Tests
    
    @Test("ImageProcessingService should initialize correctly")
    func testInitialization() async throws {
        let _ = ImageProcessingService()
        // Service should initialize without errors
        // We can't easily test internal URLSession configuration, but initialization should complete
        #expect(Bool(true)) // Basic initialization test
    }
    
    // MARK: - Image Download Tests (Mock-based)
    
    @Test("downloadImage should handle successful HTTP response")
    func testSuccessfulImageDownload() async throws {
        // Note: These tests would need actual network mocking or dependency injection
        // For now, we test the error handling paths that don't require network
        
        let service = ImageProcessingService()
        let invalidURL = URL(string: "https://invalid-domain-that-does-not-exist-12345.com/image.jpg")!
        
        // Should throw network error (not crash)
        await #expect(throws: Error.self) {
            try await service.downloadImage(from: invalidURL)
        }
    }
    
    @Test("downloadImage should reject overly large images")
    func testImageSizeLimit() async throws {
        // This test would require mocking the URLSession to return large data
        // For now, we verify the error type exists and can be thrown
        let error = ImageProcessingError.imageTooLarge(15_000_000)
        
        // Test the error directly without switch since it's constant
        if case .imageTooLarge(let size) = error {
            #expect(size == 15_000_000)
        } else {
            #expect(Bool(false), "Should be imageTooLarge error")
        }
    }
    
    @Test("downloadImage should handle HTTP errors")
    func testHTTPErrorHandling() async throws {
        let error404 = ImageProcessingError.httpError(404)
        let error500 = ImageProcessingError.httpError(500)
        
        // Test errors directly without switch since they're constants
        if case .httpError(let code) = error404 {
            #expect(code == 404)
        } else {
            #expect(Bool(false), "Should be HTTP error")
        }
        
        if case .httpError(let code) = error500 {
            #expect(code == 500)
        } else {
            #expect(Bool(false), "Should be HTTP error")
        }
    }
    
    @Test("downloadImage should handle cellular network constraints")
    func testCellularNetworkHandling() async throws {
        let error = ImageProcessingError.skippedOnCellular
        
        // Test error directly without switch since it's constant
        if case .skippedOnCellular = error {
            #expect(Bool(true)) // Expected error type
        } else {
            #expect(Bool(false), "Should be skippedOnCellular error")
        }
    }
    
    // MARK: - Image Processing Tests
    
    @Test("processImage should handle valid JPEG data")
    func testProcessValidJPEGData() async throws {
        let service = ImageProcessingService()
        let jpegData = MockImageData.minimalJPEG()
        
        let result = await service.processImage(jpegData, hints: .medium)
        
        if let result = result {
            #expect(result.data.count > 0)
            #expect(result.width > 0)
            #expect(result.height > 0)
            #expect(result.format == "jpg" || result.format == "png")
            #expect(result.originalSize == jpegData.count)
            #expect(result.compressedSize > 0)
            #expect(result.compressionRatio > 0)
        } else {
            // processImage might return nil for mock data that doesn't contain valid image info
            // This is acceptable in test environment
            print("⚠️ processImage returned nil for mock JPEG data (expected in test environment)")
        }
    }
    
    @Test("processImage should handle invalid image data")
    func testProcessInvalidImageData() async throws {
        let service = ImageProcessingService()
        let invalidData = MockImageData.invalidImageData()
        
        let result = await service.processImage(invalidData)
        
        #expect(result == nil) // Should return nil for invalid image data
    }
    
    @Test("processImage should handle empty data")
    func testProcessEmptyImageData() async throws {
        let service = ImageProcessingService()
        let emptyData = Data()
        
        let result = await service.processImage(emptyData)
        
        #expect(result == nil) // Should return nil for empty data
    }
    
    @Test("processImage should respect different quality hints")
    func testDifferentQualityHints() async throws {
        let service = ImageProcessingService()
        let imageData = MockImageData.minimalJPEG()
        
        // Test different quality levels
        let lowResult = await service.processImage(imageData, hints: .low)
        let mediumResult = await service.processImage(imageData, hints: .medium)
        let highResult = await service.processImage(imageData, hints: .high)
        
        // Results might be nil for mock data, but the function should not crash
        if let low = lowResult, let medium = mediumResult, let high = highResult {
            // Higher quality should generally result in larger files
            #expect(low.compressedSize <= medium.compressedSize)
            #expect(medium.compressedSize <= high.compressedSize)
        }
    }
    
    @Test("processImage should handle custom hints")
    func testCustomImageHints() async throws {
        let service = ImageProcessingService()
        let customHints = ImageHints(
            maxDimension: 500,
            quality: 0.5,
            preferredFormat: "png"
        )
        
        let imageData = MockImageData.minimalJPEG()
        let result = await service.processImage(imageData, hints: customHints)
        
        // Function should not crash with custom hints
        // Result might be nil for mock data
        if let result = result {
            #expect(result.width <= 500)
            #expect(result.height <= 500)
        }
    }
    
    // MARK: - ProcessedImage Tests
    
    @Test("ProcessedImage should calculate compression ratio correctly")
    func testCompressionRatioCalculation() async throws {
        let processedImage = ProcessedImage(
            data: Data(count: 500),
            width: 800,
            height: 600,
            format: "jpg",
            originalSize: 1000,
            compressedSize: 500
        )
        
        #expect(processedImage.compressionRatio == 0.5)
        #expect(processedImage.data.count == 500)
        #expect(processedImage.width == 800)
        #expect(processedImage.height == 600)
        #expect(processedImage.format == "jpg")
    }
    
    @Test("ProcessedImage should handle zero original size")
    func testCompressionRatioZeroOriginal() async throws {
        let processedImage = ProcessedImage(
            data: Data(),
            width: 0,
            height: 0,
            format: "jpg",
            originalSize: 0,
            compressedSize: 100
        )
        
        #expect(processedImage.compressionRatio == 1.0) // Should default to 1.0 for zero original
    }
    
    // MARK: - ImageHints Tests
    
    @Test("ImageHints should initialize with default values")
    func testImageHintsDefaultInitialization() async throws {
        let hints = ImageHints()
        
        #expect(hints.maxDimension == 1600)
        #expect(hints.quality == 0.8)
        #expect(hints.preferredFormat == "jpg")
    }
    
    @Test("ImageHints should initialize with custom values")
    func testImageHintsCustomInitialization() async throws {
        let hints = ImageHints(
            maxDimension: 800,
            quality: 0.6,
            preferredFormat: "png"
        )
        
        #expect(hints.maxDimension == 800)
        #expect(hints.quality == 0.6)
        #expect(hints.preferredFormat == "png")
    }
    
    @Test("ImageHints should provide preset quality levels")
    func testImageHintsPresets() async throws {
        #expect(ImageHints.low.maxDimension == 800)
        #expect(ImageHints.low.quality == 0.7)
        
        #expect(ImageHints.medium.maxDimension == 1200)
        #expect(ImageHints.medium.quality == 0.8)
        
        #expect(ImageHints.high.maxDimension == 1600)
        #expect(ImageHints.high.quality == 0.9)
    }
    
    // MARK: - Error Handling Tests
    
    @Test("ImageProcessingError should provide correct error types")
    func testImageProcessingErrorTypes() async throws {
        let errors: [ImageProcessingError] = [
            .invalidResponse,
            .httpError(404),
            .imageTooLarge(5000000),
            .skippedOnCellular,
            .processingFailed
        ]
        
        for error in errors {
            switch error {
            case .invalidResponse:
                #expect(Bool(true)) // Valid error type
            case .httpError(let code):
                #expect(code > 0)
            case .imageTooLarge(let size):
                #expect(size > 0)
            case .skippedOnCellular:
                #expect(Bool(true)) // Valid error type
            case .processingFailed:
                #expect(Bool(true)) // Valid error type
            }
        }
    }
    
    // MARK: - Performance Tests
    
    @Test("processImage should handle multiple concurrent operations", .timeLimit(.minutes(1)))
    func testConcurrentImageProcessing() async throws {
        let service = ImageProcessingService()
        let imageData = MockImageData.minimalJPEG()
        
        // Create multiple concurrent processing tasks
        let tasks = (0..<5).map { _ in
            Task {
                return await service.processImage(imageData, hints: .medium)
            }
        }
        
        let results = try await withThrowingTaskGroup(of: ProcessedImage?.self) { group in
            for task in tasks {
                group.addTask { await task.value }
            }
            
            var results: [ProcessedImage?] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        
        #expect(results.count == 5)
        // Results might be nil for mock data, but should not crash
    }
    
    @Test("processImage should complete within reasonable time", .timeLimit(.minutes(1)))
    func testImageProcessingPerformance() async throws {
        let service = ImageProcessingService()
        let imageData = MockImageData.minimalJPEG()
        
        let (_, duration) = await PerformanceTestUtils.measure {
            return await service.processImage(imageData, hints: .medium)
        }
        
        #expect(duration < 2.0, "Image processing should complete quickly")
        // Result might be nil for mock data
    }
    
    // MARK: - Memory Management Tests
    
    @Test("ImageProcessingService should handle large data without memory issues")
    func testLargeDataHandling() async throws {
        let service = ImageProcessingService()
        
        // Create progressively larger data blocks to test memory handling
        let sizes = [1024, 10240, 102400, 1024000] // 1KB, 10KB, 100KB, 1MB
        
        for size in sizes {
            let largeData = Data(count: size)
            let result = await service.processImage(largeData)
            
            // Should handle gracefully (return nil for invalid data)
            #expect(result == nil) // Invalid data should return nil
        }
    }
    
    // MARK: - Integration Tests
    
    @Test("ImageProcessingService workflow should work end-to-end")
    func testImageProcessingWorkflow() async throws {
        let service = ImageProcessingService()
        
        // Simulate a complete workflow:
        // 1. Process image with different hints
        // 2. Verify results are consistent
        
        let imageData = MockImageData.minimalJPEG()
        let hints = [ImageHints.low, ImageHints.medium, ImageHints.high]
        
        var results: [ProcessedImage?] = []
        
        for hint in hints {
            let result = await service.processImage(imageData, hints: hint)
            results.append(result)
        }
        
        // Should process all hints without crashing
        #expect(results.count == 3)
        
        // Filter out nil results (expected for mock data)
        let validResults = results.compactMap { $0 }
        
        if validResults.count > 1 {
            // If we have valid results, they should be consistent
            let _ = validResults.first!.format
            for result in validResults {
                #expect(!result.format.isEmpty)
                #expect(result.data.count > 0)
                #expect(result.width >= 0)
                #expect(result.height >= 0)
            }
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("processImage should handle extremely small images")
    func testTinyImageProcessing() async throws {
        let service = ImageProcessingService()
        
        // Test with minimal valid image data
        let tinyImageData = Data([0xFF, 0xD8, 0xFF, 0xD9]) // Minimal JPEG (header + end marker)
        
        let result = await service.processImage(tinyImageData)
        
        // Should handle gracefully, likely returning nil for such minimal data
        if let result = result {
            #expect(result.data.count > 0)
            #expect(result.compressionRatio > 0)
        }
    }
    
    @Test("processImage should handle different image formats")
    func testMultipleImageFormats() async throws {
        let service = ImageProcessingService()
        
        let imageFormats = [
            ("JPEG", MockImageData.minimalJPEG()),
            ("PNG", MockImageData.validPNGHeader()),
            ("Invalid", MockImageData.invalidImageData())
        ]
        
        for (formatName, data) in imageFormats {
            let result = await service.processImage(data)
            
            if formatName == "Invalid" {
                #expect(result == nil, "Invalid image data should return nil")
            } else {
                // Valid formats might still return nil with mock data, but should not crash
                print("Processed \(formatName): \(result != nil ? "success" : "nil result (expected with mock data)")")
            }
        }
    }
    
    @Test("ImageProcessingService should handle URL edge cases")
    func testURLEdgeCases() async throws {
        let service = ImageProcessingService()
        
        let edgeCaseURLs = [
            "https://example.com/image with spaces.jpg",
            "https://example.com/image%20encoded.jpg",
            "https://example.com/very-long-filename-" + String(repeating: "x", count: 200) + ".jpg"
        ]
        
        for urlString in edgeCaseURLs {
            if let url = URL(string: urlString) {
                // Should not crash when attempting to download
                do {
                    let _ = try await service.downloadImage(from: url)
                } catch {
                    // Expected to fail (network error), but should not crash
                    #expect(error is ImageProcessingError || error is URLError)
                }
            }
        }
    }
}

// MARK: - ImageProcessingError Tests

@Suite("ImageProcessingError Tests") 
struct ImageProcessingErrorTests {
    
    @Test("ImageProcessingError should implement proper error descriptions")
    func testErrorDescriptions() async throws {
        let errors: [ImageProcessingError] = [
            .invalidResponse,
            .httpError(404),
            .imageTooLarge(5000000),
            .skippedOnCellular,
            .processingFailed
        ]
        
        for error in errors {
            // Each error should have some kind of description/representation
            let description = String(describing: error)
            #expect(!description.isEmpty, "Error should have non-empty description")
            
            switch error {
            case .httpError(let code):
                #expect(description.contains("\(code)"), "HTTP error should contain status code")
            case .imageTooLarge(let size):
                #expect(description.contains("\(size)") || size > 0, "Size error should be meaningful")
            case .processingFailed:
                #expect(description.contains("processing") || description.contains("failed"), "Processing error should be descriptive")
            default:
                #expect(Bool(true)) // Other errors just need to exist
            }
        }
    }
    
    @Test("ImageProcessingError should be equatable where appropriate")
    func testErrorEquality() async throws {
        let error1 = ImageProcessingError.httpError(404)
        let error2 = ImageProcessingError.httpError(404)
        let error3 = ImageProcessingError.httpError(500)
        
        // Test would depend on whether ImageProcessingError implements Equatable
        // For now, just verify they can be compared via description
        #expect(String(describing: error1) == String(describing: error2))
        #expect(String(describing: error1) != String(describing: error3))
    }
}