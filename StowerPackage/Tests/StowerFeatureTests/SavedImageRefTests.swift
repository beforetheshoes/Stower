import Testing
import Foundation
import SwiftData
@testable import StowerFeature

@MainActor
@Suite("SavedImageRef Tests")
struct SavedImageRefTests {
    
    // MARK: - Initialization Tests
    
    @Test("SavedImageRef should initialize with default values")
    func testDefaultInitialization() async throws {
        let imageRef = SavedImageRef()
        
        #expect(imageRef.id != UUID()) // Should have a unique ID
        #expect(imageRef.sourceURL == nil)
        #expect(imageRef.width == 0)
        #expect(imageRef.height == 0)
        #expect(imageRef.sha256 == "")
        #expect(imageRef.origin == .web) // Default origin
        #expect(imageRef.hasLocalFile == false)
        #expect(imageRef.downloadStatus == .pending) // Default status
        #expect(imageRef.fileFormat == "jpg") // Default format
        #expect(imageRef.createdAt.timeIntervalSince1970 > 0)
        #expect(imageRef.lastDownloadAttempt == nil)
        #expect(imageRef.downloadFailureCount == 0)
        #expect(imageRef.item == nil) // No relationship by default
    }
    
    @Test("SavedImageRef should initialize with custom values")
    func testCustomInitialization() async throws {
        let url = URL(string: "https://example.com/image.png")!
        let imageRef = SavedImageRef(
            sourceURL: url,
            width: 1024,
            height: 768,
            sha256: "abc123def456",
            origin: .pdf,
            fileFormat: "png"
        )
        
        #expect(imageRef.sourceURL == url)
        #expect(imageRef.width == 1024)
        #expect(imageRef.height == 768)
        #expect(imageRef.sha256 == "abc123def456")
        #expect(imageRef.origin == .pdf)
        #expect(imageRef.fileFormat == "png")
        #expect(imageRef.downloadStatus == .pending)
        #expect(imageRef.hasLocalFile == false)
    }
    
    @Test("SavedImageRef should initialize with specific UUID")
    func testUUIDInitialization() async throws {
        let specificId = UUID()
        let url = URL(string: "https://example.com/image.jpg")!
        
        let imageRef = SavedImageRef(
            id: specificId,
            sourceURL: url,
            width: 800,
            height: 600
        )
        
        #expect(imageRef.id == specificId)
        #expect(imageRef.sourceURL == url)
        #expect(imageRef.width == 800)
        #expect(imageRef.height == 600)
    }
    
    // MARK: - Domain Extraction Tests
    
    @Test("domain should extract host from sourceURL")
    func testDomainExtraction() async throws {
        let imageRef = SavedImageRef(
            sourceURL: URL(string: "https://example.com/path/image.jpg")
        )
        
        #expect(imageRef.domain == "example.com")
        
        let subdomainRef = SavedImageRef(
            sourceURL: URL(string: "https://cdn.example.com/image.jpg")
        )
        
        #expect(subdomainRef.domain == "cdn.example.com")
    }
    
    @Test("domain should handle various URL formats")
    func testDomainExtractionVariousFormats() async throws {
        let testCases: [(String, String?)] = [
            ("https://example.com/image.jpg", "example.com"),
            ("http://example.com/image.jpg", "example.com"),
            ("https://sub.example.com/path/image.jpg", "sub.example.com"),
            ("https://example.com:8080/image.jpg", "example.com"),
            ("invalid-url", nil),
        ]
        
        for (urlString, expectedDomain) in testCases {
            let imageRef = SavedImageRef(sourceURL: URL(string: urlString))
            #expect(imageRef.domain == expectedDomain, "Failed for URL: \(urlString)")
        }
    }
    
    @Test("domain should return nil for nil sourceURL")
    func testDomainNilURL() async throws {
        let imageRef = SavedImageRef(sourceURL: nil)
        #expect(imageRef.domain == nil)
    }
    
    // MARK: - Download Status Management Tests
    
    @Test("Download status should start as pending")
    func testInitialDownloadStatus() async throws {
        let imageRef = SavedImageRef()
        #expect(imageRef.downloadStatus == .pending)
        #expect(!imageRef.hasLocalFile)
    }
    
    @Test("markDownloadInProgress should update status and timestamp")
    func testMarkDownloadInProgress() async throws {
        let imageRef = SavedImageRef()
        let beforeTime = Date()
        
        imageRef.markDownloadInProgress()
        
        #expect(imageRef.downloadStatus == .inProgress)
        #expect(imageRef.lastDownloadAttempt != nil)
        #expect(imageRef.lastDownloadAttempt! >= beforeTime)
        #expect(!imageRef.hasLocalFile)
    }
    
    @Test("markDownloadSuccess should update status and reset failure count")
    func testMarkDownloadSuccess() async throws {
        let imageRef = SavedImageRef()
        
        // Simulate some failures first
        imageRef.markDownloadFailure()
        imageRef.markDownloadFailure()
        #expect(imageRef.downloadFailureCount == 2)
        
        let beforeTime = Date()
        imageRef.markDownloadSuccess()
        
        #expect(imageRef.downloadStatus == .completed)
        #expect(imageRef.hasLocalFile == true)
        #expect(imageRef.downloadFailureCount == 0) // Should reset
        #expect(imageRef.lastDownloadAttempt != nil)
        #expect(imageRef.lastDownloadAttempt! >= beforeTime)
    }
    
    @Test("markDownloadFailure should increment failure count")
    func testMarkDownloadFailure() async throws {
        let imageRef = SavedImageRef()
        
        let beforeTime = Date()
        imageRef.markDownloadFailure()
        
        #expect(imageRef.downloadStatus == .failed)
        #expect(imageRef.hasLocalFile == false)
        #expect(imageRef.downloadFailureCount == 1)
        #expect(imageRef.lastDownloadAttempt != nil)
        #expect(imageRef.lastDownloadAttempt! >= beforeTime)
        
        // Second failure
        imageRef.markDownloadFailure()
        #expect(imageRef.downloadFailureCount == 2)
        #expect(imageRef.downloadStatus == .failed)
    }
    
    // MARK: - Retry Logic Tests
    
    @Test("shouldRetryDownload should return false for non-failed status")
    func testShouldRetryDownloadNonFailed() async throws {
        let imageRef = SavedImageRef()
        
        // Pending status
        #expect(!imageRef.shouldRetryDownload)
        
        // In progress status
        imageRef.markDownloadInProgress()
        #expect(!imageRef.shouldRetryDownload)
        
        // Completed status
        imageRef.markDownloadSuccess()
        #expect(!imageRef.shouldRetryDownload)
    }
    
    @Test("shouldRetryDownload should respect max retry limit")
    func testShouldRetryDownloadMaxLimit() async throws {
        let imageRef = SavedImageRef()
        
        // First failure - should retry after backoff
        imageRef.markDownloadFailure()
        imageRef.lastDownloadAttempt = Date().addingTimeInterval(-3700) // 1 hour + 1 minute ago
        #expect(imageRef.shouldRetryDownload)
        
        // Second failure - should retry after backoff
        imageRef.markDownloadFailure()
        imageRef.lastDownloadAttempt = Date().addingTimeInterval(-7300) // 2 hours + 1 minute ago
        #expect(imageRef.shouldRetryDownload)
        
        // Third failure - should retry after backoff
        imageRef.markDownloadFailure()
        imageRef.lastDownloadAttempt = Date().addingTimeInterval(-10900) // 3 hours + 1 minute ago
        #expect(imageRef.shouldRetryDownload)
        
        // Fourth failure - should NOT retry (exceeded max 3 retries)
        imageRef.markDownloadFailure()
        imageRef.lastDownloadAttempt = Date().addingTimeInterval(-14500) // 4+ hours ago
        #expect(!imageRef.shouldRetryDownload)
    }
    
    @Test("shouldRetryDownload should respect backoff timing")
    func testShouldRetryDownloadBackoff() async throws {
        let imageRef = SavedImageRef()
        
        imageRef.markDownloadFailure()
        
        // Should not retry immediately after failure (needs 1 hour backoff)
        #expect(!imageRef.shouldRetryDownload)
        
        // Test by manipulating the lastDownloadAttempt to simulate time passage
        imageRef.lastDownloadAttempt = Date().addingTimeInterval(-3700) // 1 hour + 1 minute ago
        #expect(imageRef.shouldRetryDownload)
        
        // Test second failure (needs 2 hour backoff)
        imageRef.markDownloadFailure()
        imageRef.lastDownloadAttempt = Date().addingTimeInterval(-3600) // 1 hour ago
        #expect(!imageRef.shouldRetryDownload)
        
        imageRef.lastDownloadAttempt = Date().addingTimeInterval(-7300) // 2+ hours ago
        #expect(imageRef.shouldRetryDownload)
    }
    
    @Test("shouldRetryDownload should handle nil lastDownloadAttempt")
    func testShouldRetryDownloadNilTimestamp() async throws {
        let imageRef = SavedImageRef()
        
        // Manually set to failed without using markDownloadFailure
        imageRef.downloadStatus = .failed
        imageRef.downloadFailureCount = 1
        imageRef.lastDownloadAttempt = nil
        
        #expect(imageRef.shouldRetryDownload) // Should retry when no timestamp
    }
    
    // MARK: - Raw Status Handling Tests
    
    @Test("downloadStatus should handle unknown raw values gracefully")
    func testDownloadStatusUnknownRawValue() async throws {
        let imageRef = SavedImageRef()
        
        // Set an unknown raw value
        imageRef.downloadStatusRaw = "unknown_status"
        
        // Should default to pending
        #expect(imageRef.downloadStatus == .pending)
        
        // Setting a valid status should work
        imageRef.downloadStatus = .completed
        #expect(imageRef.downloadStatusRaw == ImageDownloadStatus.completed.rawValue)
        #expect(imageRef.downloadStatus == .completed)
    }
    
    // MARK: - SwiftData Relationship Tests
    
    @Test("SavedImageRef should establish relationship with SavedItem")
    func testSavedItemRelationship() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let item = TestDataFactory.createSavedItem()
        let imageRef = TestDataFactory.createSavedImageRef()
        
        imageRef.item = item
        
        context.insert(item)
        context.insert(imageRef)
        try context.save()
        
        #expect(imageRef.item === item)
        
        // Fetch from context to verify persistence
        let fetchDescriptor = FetchDescriptor<SavedImageRef>()
        let fetchedRefs = try context.fetch(fetchDescriptor)
        
        #expect(fetchedRefs.count == 1)
        let fetchedRef = fetchedRefs.first!
        #expect(fetchedRef.item?.title == item.title)
    }
    
    // MARK: - SwiftData Persistence Tests
    
    @Test("SavedImageRef should persist all properties")
    func testSwiftDataPersistence() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let url = URL(string: "https://example.com/test.jpg")!
        let imageRef = SavedImageRef(
            sourceURL: url,
            width: 1920,
            height: 1080,
            sha256: "test_hash_123",
            origin: .web,
            fileFormat: "jpg"
        )
        
        imageRef.markDownloadInProgress()
        imageRef.markDownloadSuccess()
        
        context.insert(imageRef)
        try context.save()
        
        let fetchDescriptor = FetchDescriptor<SavedImageRef>()
        let fetchedRefs = try context.fetch(fetchDescriptor)
        
        #expect(fetchedRefs.count == 1)
        let retrieved = fetchedRefs.first!
        
        #expect(retrieved.sourceURL == url)
        #expect(retrieved.width == 1920)
        #expect(retrieved.height == 1080)
        #expect(retrieved.sha256 == "test_hash_123")
        #expect(retrieved.origin == .web)
        #expect(retrieved.fileFormat == "jpg")
        #expect(retrieved.downloadStatus == .completed)
        #expect(retrieved.hasLocalFile == true)
        #expect(retrieved.downloadFailureCount == 0)
    }
    
    @Test("SavedImageRef should persist download failure history")
    func testPersistDownloadFailureHistory() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let imageRef = SavedImageRef()
        imageRef.markDownloadFailure()
        imageRef.markDownloadFailure()
        imageRef.markDownloadFailure()
        
        context.insert(imageRef)
        try context.save()
        
        let fetchDescriptor = FetchDescriptor<SavedImageRef>()
        let fetchedRefs = try context.fetch(fetchDescriptor)
        
        #expect(fetchedRefs.count == 1)
        let retrieved = fetchedRefs.first!
        
        #expect(retrieved.downloadStatus == .failed)
        #expect(retrieved.downloadFailureCount == 3)
        #expect(retrieved.lastDownloadAttempt != nil)
        #expect(!retrieved.shouldRetryDownload) // Should not retry after 3 failures
    }
    
    // MARK: - Edge Cases and Error Handling
    
    @Test("SavedImageRef should handle extreme dimensions")
    func testExtremeDimensions() async throws {
        let imageRef = SavedImageRef(
            width: Int.max,
            height: Int.max
        )
        
        #expect(imageRef.width == Int.max)
        #expect(imageRef.height == Int.max)
    }
    
    @Test("SavedImageRef should handle very long SHA256")
    func testVeryLongSHA256() async throws {
        let longHash = String(repeating: "a", count: 1000)
        let imageRef = SavedImageRef(sha256: longHash)
        
        #expect(imageRef.sha256 == longHash)
    }
    
    @Test("SavedImageRef should handle special characters in file format")
    func testSpecialCharactersInFileFormat() async throws {
        let imageRef = SavedImageRef(fileFormat: "jpeg.special-format_v2")
        
        #expect(imageRef.fileFormat == "jpeg.special-format_v2")
    }
    
    // MARK: - Performance Tests
    
    @Test("SavedImageRef operations should be performant", .timeLimit(.minutes(1)))
    func testPerformance() async throws {
        let (imageRef, creationDuration) = await PerformanceTestUtils.measure {
            return SavedImageRef(
                sourceURL: URL(string: "https://example.com/image.jpg"),
                width: 1920,
                height: 1080
            )
        }
        
        #expect(creationDuration < 0.05, "ImageRef creation should be very fast")
        
        let (_, statusUpdateDuration) = await PerformanceTestUtils.measure { @MainActor in
            imageRef.markDownloadInProgress()
            imageRef.markDownloadSuccess()
            imageRef.markDownloadFailure()
        }
        
        #expect(statusUpdateDuration < 0.5, "Status updates should complete within reasonable time")
    }
    
    // MARK: - Multiple ImageRefs Tests
    
    @Test("Multiple SavedImageRefs should maintain independence")
    func testMultipleImageRefsIndependence() async throws {
        let context = try ModelContext.inMemoryContext()
        
        let ref1 = SavedImageRef(
            sourceURL: URL(string: "https://site1.com/image1.jpg"),
            origin: .web
        )
        
        let ref2 = SavedImageRef(
            sourceURL: URL(string: "https://site2.com/image2.png"),
            origin: .pdf
        )
        
        ref1.markDownloadSuccess()
        ref2.markDownloadFailure()
        
        context.insert(ref1)
        context.insert(ref2)
        try context.save()
        
        // Verify independence
        #expect(ref1.id != ref2.id)
        #expect(ref1.domain == "site1.com")
        #expect(ref2.domain == "site2.com")
        #expect(ref1.downloadStatus == .completed)
        #expect(ref2.downloadStatus == .failed)
        #expect(ref1.downloadFailureCount == 0)
        #expect(ref2.downloadFailureCount == 1)
    }
    
    // MARK: - Backoff Calculation Tests
    
    @Test("Backoff calculation should work correctly for different failure counts")
    func testBackoffCalculation() async throws {
        let imageRef = SavedImageRef()
        
        // Test backoff intervals by manipulating failure count
        let testCases: [(Int, TimeInterval)] = [
            (1, 3600),    // 1 hour for first retry
            (2, 7200),    // 2 hours for second retry  
            (3, 10800),   // 3 hours for third retry (linear backoff)
        ]
        
        for (failureCount, expectedBackoff) in testCases {
            imageRef.downloadFailureCount = failureCount
            imageRef.downloadStatus = .failed
            imageRef.lastDownloadAttempt = Date().addingTimeInterval(-expectedBackoff + 60) // 1 minute before required time
            
            #expect(!imageRef.shouldRetryDownload, "Should not retry before backoff period for \(failureCount) failures")
            
            imageRef.lastDownloadAttempt = Date().addingTimeInterval(-expectedBackoff - 60) // 1 minute after required time
            
            #expect(imageRef.shouldRetryDownload, "Should retry after backoff period for \(failureCount) failures")
        }
    }
}

// MARK: - ImageDownloadStatus Enum Tests

@Suite("ImageDownloadStatus Tests")
struct ImageDownloadStatusTests {
    
    @Test("ImageDownloadStatus should have correct display names")
    func testImageDownloadStatusDisplayNames() async throws {
        #expect(ImageDownloadStatus.pending.displayName == "Pending")
        #expect(ImageDownloadStatus.inProgress.displayName == "Downloading")
        #expect(ImageDownloadStatus.completed.displayName == "Downloaded")
        #expect(ImageDownloadStatus.failed.displayName == "Failed")
        #expect(ImageDownloadStatus.skipped.displayName == "Skipped")
    }
    
    @Test("ImageDownloadStatus should be Codable")
    func testImageDownloadStatusCodable() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for status in ImageDownloadStatus.allCases {
            let encoded = try encoder.encode(status)
            let decoded = try decoder.decode(ImageDownloadStatus.self, from: encoded)
            #expect(decoded == status)
        }
    }
    
    @Test("ImageDownloadStatus should have all expected cases")
    func testImageDownloadStatusAllCases() async throws {
        let allCases = ImageDownloadStatus.allCases
        #expect(allCases.count == 5)
        #expect(allCases.contains(.pending))
        #expect(allCases.contains(.inProgress))
        #expect(allCases.contains(.completed))
        #expect(allCases.contains(.failed))
        #expect(allCases.contains(.skipped))
    }
    
    @Test("ImageDownloadStatus should handle raw values correctly")
    func testImageDownloadStatusRawValues() async throws {
        #expect(ImageDownloadStatus.pending.rawValue == "pending")
        #expect(ImageDownloadStatus.inProgress.rawValue == "inProgress")
        #expect(ImageDownloadStatus.completed.rawValue == "completed")
        #expect(ImageDownloadStatus.failed.rawValue == "failed")
        #expect(ImageDownloadStatus.skipped.rawValue == "skipped")
        
        // Test reverse lookup
        #expect(ImageDownloadStatus(rawValue: "pending") == .pending)
        #expect(ImageDownloadStatus(rawValue: "inProgress") == .inProgress)
        #expect(ImageDownloadStatus(rawValue: "completed") == .completed)
        #expect(ImageDownloadStatus(rawValue: "failed") == .failed)
        #expect(ImageDownloadStatus(rawValue: "skipped") == .skipped)
        #expect(ImageDownloadStatus(rawValue: "invalid") == nil)
    }
}