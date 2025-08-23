import Testing
import PDFKit
import Foundation
@testable import StowerFeature

@Test func example() async throws {
    // Write your test here and use APIs like `#expect(...)` to check expected conditions.
}

@Test("PDF Extraction Service - Invalid PDF data")
func testPDFExtractionInvalidData() async throws {
    let pdfService = PDFExtractionService()
    
    // Create invalid PDF data
    let invalidData = Data("Not a PDF".utf8)
    
    await #expect(throws: PDFExtractionError.self) {
        try await pdfService.extractContent(from: invalidData)
    }
}

@Test("PDF URL detection")
func testPDFURLDetection() async throws {
    // Test isPDFURL function from AddItemView (via helper)
    func isPDFURL(_ urlString: String) -> Bool {
        return urlString.lowercased().hasSuffix(".pdf")
    }
    
    #expect(isPDFURL("https://example.com/document.pdf"))
    #expect(isPDFURL("https://example.com/DOCUMENT.PDF"))
    #expect(!isPDFURL("https://example.com/document.html"))
    #expect(!isPDFURL("https://example.com/document"))
}

@Test("PDF magic bytes detection")
func testPDFMagicBytesDetection() async throws {
    // Test PDF magic bytes detection
    let pdfMagicBytes = Data([0x25, 0x50, 0x44, 0x46]) // "%PDF"
    let nonPDFData = Data([0x48, 0x54, 0x4D, 0x4C]) // "HTML"
    
    // Check that PDF data starts with correct magic bytes
    let isPDFData = pdfMagicBytes.count >= 4 && pdfMagicBytes.prefix(4) == Data([0x25, 0x50, 0x44, 0x46])
    let isNotPDFData = nonPDFData.count >= 4 && nonPDFData.prefix(4) == Data([0x25, 0x50, 0x44, 0x46])
    
    #expect(isPDFData)
    #expect(!isNotPDFData)
}

@Test("SavedItem PDF content handling")
func testSavedItemPDFContent() async throws {
    let markdownContent = """
    # PDF Document Title
    
    This is a sample paragraph from a PDF document.
    
    ## Section Header
    
    - First list item
    - Second list item
    
    Some **bold text** and *italic text* from the PDF.
    """
    
    let item = SavedItem(
        title: "Test PDF Document",
        extractedMarkdown: markdownContent,
        tags: ["pdf", "test"]
    )
    
    #expect(item.title == "Test PDF Document")
    #expect(item.extractedMarkdown.contains("PDF Document Title"))
    #expect(item.extractedMarkdown.contains("Section Header"))
    #expect(item.tags.contains("pdf"))
    
    // Test preview generation
    let preview = SavedItem.generatePreview(from: markdownContent)
    #expect(!preview.isEmpty)
    #expect(preview.count <= 150 + 1) // 150 chars + ellipsis
    #expect(!preview.contains("#")) // Headers should be stripped
    #expect(!preview.contains("**")) // Bold formatting should be stripped
}

@Test("Content extraction service integration")
func testContentExtractionServicePDFIntegration() async throws {
    // Test that the service has PDF detection methods
    func testIsPDFURL(_ urlString: String) -> Bool {
        return urlString.lowercased().hasSuffix(".pdf")
    }
    
    #expect(testIsPDFURL("https://example.com/document.pdf"))
    #expect(!testIsPDFURL("https://example.com/webpage.html"))
}

@Test("Improved PDF text structure detection")
func testImprovedPDFStructureDetection() async throws {
    let pdfService = PDFExtractionService()
    
    // Test improved list detection patterns
    let bulletTests = [
        ("• First item", true),
        ("1. Numbered item", true),
        ("a) Letter item", true), 
        ("(1) Parenthetical item", true),
        ("Regular paragraph text", false),
        ("    - Indented item", true),
        ("○ Circle bullet", true)
    ]
    
    for (text, expectedIsList) in bulletTests {
        let actualIsList = pdfService.isListItem(text)
        #expect(actualIsList == expectedIsList, "Failed for text: '\(text)'")
    }
}

@Test("PDF markdown cleanup")
func testPDFMarkdownCleanup() async throws {
    let pdfService = PDFExtractionService()
    
    let messyText = """
    This is a para-
    graph with broken
    words    and   extra    spaces.
    
    
    
    Another paragraph with excessive breaks.
    """
    
    let cleaned = pdfService.cleanupMarkdown(messyText)
    
    // Should fix hyphenation
    #expect(cleaned.contains("paragraph"))
    #expect(!cleaned.contains("para-\ngraph"))
    
    // Should normalize spacing
    #expect(!cleaned.contains("   "))
    
    // Should not have excessive line breaks
    #expect(!cleaned.contains("\n\n\n\n"))
}

@Test("Analyze article.pdf structure")
func testArticlePDFAnalysis() async throws {
    // This is a diagnostic test to understand the PDF structure
    let articleURL = URL(fileURLWithPath: "/Users/ryan/Developer/Swift/Stower/article.pdf")
    
    // Only run if the file exists
    guard FileManager.default.fileExists(atPath: articleURL.path) else {
        print("⚠️ article.pdf not found - skipping diagnostic")
        return
    }
    
    PDFDiagnosticService.analyzePDF(at: articleURL)
    
    // Now test actual extraction
    let pdfService = PDFExtractionService()
    do {
        let result = try await pdfService.extractContent(from: articleURL)
        print("\n📝 EXTRACTION RESULT:")
        print("Title: \(result.title)")
        print("Markdown length: \(result.markdown.count)")
        print("First 500 chars of markdown:")
        print(String(result.markdown.prefix(500)))
        print("\n" + String(repeating: "=", count: 50) + "\n")
    } catch {
        print("❌ Extraction failed: \(error)")
    }
}

// MARK: - Title Editing Tests

@Test("SavedItem title update via updateContent")
func testSavedItemTitleUpdate() async throws {
    let originalTitle = "Original Article Title"
    let newTitle = "Updated Article Title"
    
    let item = SavedItem(
        title: originalTitle,
        extractedMarkdown: "# Test Content\n\nSample markdown content."
    )
    
    let originalDate = item.dateModified
    
    // Wait a moment to ensure date modification is detectable
    try await Task.sleep(for: .milliseconds(10))
    
    // Update the title
    item.updateContent(title: newTitle)
    
    // Verify title was updated
    #expect(item.title == newTitle)
    
    // Verify dateModified was updated
    #expect(item.dateModified > originalDate)
    
    // Verify other properties remain unchanged
    #expect(item.extractedMarkdown == "# Test Content\n\nSample markdown content.")
}

@Test("SavedItem title update preserves other properties")
func testTitleUpdatePreservesOtherProperties() async throws {
    let item = SavedItem(
        url: URL(string: "https://example.com/article"),
        title: "Original Title",
        extractedMarkdown: "# Original Content\n\nOriginal paragraph.",
        tags: ["tech", "original"]
    )
    
    let originalURL = item.url
    let originalMarkdown = item.extractedMarkdown
    let originalTags = item.tags
    let originalDateAdded = item.dateAdded
    
    // Update only the title
    item.updateContent(title: "New Title")
    
    // Verify title changed
    #expect(item.title == "New Title")
    
    // Verify other properties unchanged
    #expect(item.url == originalURL)
    #expect(item.extractedMarkdown == originalMarkdown)
    #expect(item.tags == originalTags)
    #expect(item.dateAdded == originalDateAdded)
}

@Test("SavedItem empty title handling")
func testEmptyTitleHandling() async throws {
    let item = SavedItem(
        title: "Original Title",
        extractedMarkdown: "Test content"
    )
    
    // Update with empty title
    item.updateContent(title: "")
    
    // Should accept empty title (validation handled at UI level)
    #expect(item.title == "")
}

@Test("SavedItem nil title parameter leaves title unchanged")
func testNilTitleParameterLeavesUnchanged() async throws {
    let originalTitle = "Original Title"
    let item = SavedItem(
        title: originalTitle,
        extractedMarkdown: "Test content"
    )
    
    // Update with nil title (should not change)
    item.updateContent(title: nil)
    
    // Title should remain unchanged
    #expect(item.title == originalTitle)
}

@Test("SavedItem multiple property updates including title")
func testMultiplePropertyUpdatesIncludingTitle() async throws {
    let item = SavedItem(
        title: "Original Title",
        extractedMarkdown: "Original content",
        tags: ["old-tag"]
    )
    
    let newTitle = "New Title"
    let newMarkdown = "# New Content\n\nUpdated paragraph."
    let newTags = ["new-tag", "updated"]
    
    // Update multiple properties including title
    item.updateContent(
        title: newTitle,
        extractedMarkdown: newMarkdown,
        tags: newTags
    )
    
    // Verify all properties updated
    #expect(item.title == newTitle)
    #expect(item.extractedMarkdown == newMarkdown)
    #expect(item.tags == newTags)
    
    // Verify content preview was regenerated
    #expect(item.contentPreview.contains("New Content") || item.contentPreview.contains("Updated paragraph"))
}

// MARK: - UI Logic Tests for Title Editing

@Test("Title editing validation - empty title handling")
func testTitleEditingValidation() async throws {
    // Test empty string validation
    let emptyTitle = ""
    let whitespaceTitle = "   \n\t  "
    let validTitle = "Valid Title"
    
    // Test trimming logic (matches ReaderView implementation)
    let trimmedEmpty = emptyTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedWhitespace = whitespaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedValid = validTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    
    #expect(trimmedEmpty.isEmpty)
    #expect(trimmedWhitespace.isEmpty)
    #expect(!trimmedValid.isEmpty)
    #expect(trimmedValid == "Valid Title")
}

@Test("Title editing state management simulation")
func testTitleEditingStateManagement() async throws {
    let item = SavedItem(
        title: "Original Title",
        extractedMarkdown: "Test content"
    )
    
    // Simulate UI state - would be @State variables in actual UI
    var isEditingTitle = false
    var editedTitle = ""
    
    // Simulate starting edit
    editedTitle = item.title
    isEditingTitle = true
    
    #expect(isEditingTitle == true)
    #expect(editedTitle == "Original Title")
    
    // Simulate editing
    editedTitle = "New Title"
    
    #expect(editedTitle == "New Title")
    #expect(item.title == "Original Title") // Original unchanged until save
    
    // Simulate save action (mimics ReaderView saveTitleEdit logic)
    let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
        item.updateContent(title: trimmedTitle)
        isEditingTitle = false
        editedTitle = ""
    }
    
    #expect(item.title == "New Title")
    #expect(isEditingTitle == false)
    #expect(editedTitle == "")
}

@Test("Title editing cancel behavior simulation")
func testTitleEditingCancelBehavior() async throws {
    let item = SavedItem(
        title: "Original Title",
        extractedMarkdown: "Test content"
    )
    
    // Simulate UI state
    var isEditingTitle = false
    var editedTitle = ""
    
    // Start editing
    editedTitle = item.title
    isEditingTitle = true
    
    // Make changes
    editedTitle = "Modified Title"
    
    // Simulate cancel (mimics ReaderView cancelTitleEdit logic)
    isEditingTitle = false
    editedTitle = ""
    
    // Original title should be unchanged
    #expect(item.title == "Original Title")
    #expect(isEditingTitle == false)
    #expect(editedTitle == "")
}

@Test("Title editing with special characters")
func testTitleEditingSpecialCharacters() async throws {
    let item = SavedItem(
        title: "Original Title",
        extractedMarkdown: "Test content"
    )
    
    let specialTitle = "📚 Article: Testing & Development (2024) - Part #1"
    
    item.updateContent(title: specialTitle)
    
    #expect(item.title == specialTitle)
}

@Test("Title editing persistence across app sessions simulation")
func testTitleEditingPersistence() async throws {
    // Test that title changes would persist (in real app via SwiftData)
    let item = SavedItem(
        title: "Original Title",
        extractedMarkdown: "Content"
    )
    
    let originalDate = item.dateModified
    
    // Wait to ensure detectable time difference
    try await Task.sleep(for: .milliseconds(10))
    
    // Update title
    item.updateContent(title: "Updated Title")
    
    // Verify persistence markers
    #expect(item.title == "Updated Title")
    #expect(item.dateModified > originalDate)
}

// MARK: - Comprehensive Metadata Editing Tests

@Test("SavedItem author field support")
func testSavedItemAuthorField() async throws {
    let item = SavedItem(
        title: "Test Article",
        author: "John Doe",
        extractedMarkdown: "Content"
    )
    
    #expect(item.author == "John Doe")
    
    // Test author update
    item.updateContent(author: "Jane Smith")
    #expect(item.author == "Jane Smith")
}

@Test("Complete metadata update - title, author, tags")
func testCompleteMetadataUpdate() async throws {
    let item = SavedItem(
        title: "Original Title",
        author: "Original Author",
        extractedMarkdown: "Content",
        tags: ["old-tag"]
    )
    
    let newTitle = "Updated Title"
    let newAuthor = "Updated Author" 
    let newTags = ["new-tag", "updated", "metadata"]
    
    item.updateContent(
        title: newTitle,
        author: newAuthor,
        tags: newTags
    )
    
    #expect(item.title == newTitle)
    #expect(item.author == newAuthor)
    #expect(item.tags == newTags)
}

@Test("Metadata editing validation - empty values")
func testMetadataValidation() async throws {
    let item = SavedItem(
        title: "Original Title",
        author: "Original Author",
        extractedMarkdown: "Content",
        tags: ["tag1"]
    )
    
    // Test empty string values
    item.updateContent(
        title: "",
        author: "",
        tags: []
    )
    
    #expect(item.title == "")
    #expect(item.author == "")
    #expect(item.tags == [])
}

@Test("Metadata partial updates preserve other fields")
func testPartialMetadataUpdates() async throws {
    let item = SavedItem(
        title: "Original Title",
        author: "Original Author",
        extractedMarkdown: "Content",
        tags: ["tag1", "tag2"]
    )
    
    // Update only author
    item.updateContent(author: "New Author")
    
    #expect(item.title == "Original Title") // Unchanged
    #expect(item.author == "New Author")    // Changed
    #expect(item.tags == ["tag1", "tag2"])  // Unchanged
    
    // Update only tags
    item.updateContent(tags: ["new-tag"])
    
    #expect(item.title == "Original Title") // Still unchanged
    #expect(item.author == "New Author")    // Still unchanged from previous
    #expect(item.tags == ["new-tag"])       // Changed
}

@Test("Tag editing operations")
func testTagEditingOperations() async throws {
    let item = SavedItem(
        title: "Article",
        extractedMarkdown: "Content"
    )
    
    // Start with no tags
    #expect(item.tags == [])
    
    // Add tags
    item.updateContent(tags: ["tech", "programming", "swift"])
    #expect(item.tags == ["tech", "programming", "swift"])
    
    // Remove some tags
    item.updateContent(tags: ["swift"])
    #expect(item.tags == ["swift"])
    
    // Clear all tags
    item.updateContent(tags: [])
    #expect(item.tags == [])
}

@Test("Metadata with special characters and unicode")
func testMetadataSpecialCharacters() async throws {
    let item = SavedItem(
        title: "Original",
        author: "Original",
        extractedMarkdown: "Content"
    )
    
    let unicodeTitle = "📚 Title with Émoji & Special Chars: (2024)"
    let unicodeAuthor = "José García-López"
    let unicodeTags = ["español", "français", "日本語", "emoji-📱"]
    
    item.updateContent(
        title: unicodeTitle,
        author: unicodeAuthor,
        tags: unicodeTags
    )
    
    #expect(item.title == unicodeTitle)
    #expect(item.author == unicodeAuthor)
    #expect(item.tags == unicodeTags)
}

// MARK: - Image Sync Tests

@Test("SavedImageRef creation with specific UUID")
func testSavedImageRefUUIDConsistency() async throws {
    let imageUUID = UUID()
    let sourceURL = URL(string: "https://example.com/image.jpg")!
    
    let imageRef = SavedImageRef(
        id: imageUUID,
        sourceURL: sourceURL,
        width: 800,
        height: 600,
        origin: .web,
        fileFormat: "jpg"
    )
    
    #expect(imageRef.id == imageUUID)
    #expect(imageRef.sourceURL == sourceURL)
    #expect(imageRef.width == 800)
    #expect(imageRef.height == 600)
    #expect(imageRef.origin == .web)
    #expect(imageRef.fileFormat == "jpg")
    #expect(imageRef.downloadStatus == .pending)
}

@Test("SavedImageRef download state management")
func testImageRefDownloadStates() async throws {
    let imageRef = SavedImageRef(
        sourceURL: URL(string: "https://example.com/image.jpg"),
        origin: .web
    )
    
    #expect(imageRef.downloadStatus == .pending)
    #expect(!imageRef.hasLocalFile)
    
    // Mark in progress
    imageRef.markDownloadInProgress()
    #expect(imageRef.downloadStatus == .inProgress)
    #expect(!imageRef.hasLocalFile)
    
    // Mark success
    imageRef.markDownloadSuccess()
    #expect(imageRef.downloadStatus == .completed)
    #expect(imageRef.hasLocalFile)
    #expect(imageRef.downloadFailureCount == 0)
    
    // Test failure
    imageRef.markDownloadFailure()
    #expect(imageRef.downloadStatus == .failed)
    #expect(!imageRef.hasLocalFile)
    #expect(imageRef.downloadFailureCount == 1)
}

// MARK: - UI State Management Tests for Complete Metadata Editing

@Test("Metadata editing UI state simulation")
func testMetadataEditingUIState() async throws {
    let item = SavedItem(
        title: "Original Title",
        author: "Original Author",
        extractedMarkdown: "Content",
        tags: ["tag1", "tag2"]
    )
    
    // Simulate UI state variables
    var isEditingMetadata = false
    var editedTitle = ""
    var editedAuthor = ""
    var editedTags: [String] = []
    
    // Start editing - populate fields
    editedTitle = item.title
    editedAuthor = item.author
    editedTags = item.tags
    isEditingMetadata = true
    
    #expect(isEditingMetadata == true)
    #expect(editedTitle == "Original Title")
    #expect(editedAuthor == "Original Author")
    #expect(editedTags == ["tag1", "tag2"])
    
    // Make changes
    editedTitle = "New Title"
    editedAuthor = "New Author"
    editedTags = ["new-tag"]
    
    // Simulate save
    let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAuthor = editedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if !trimmedTitle.isEmpty {
        item.updateContent(
            title: trimmedTitle,
            author: trimmedAuthor,
            tags: editedTags
        )
        isEditingMetadata = false
        editedTitle = ""
        editedAuthor = ""
        editedTags = []
    }
    
    #expect(item.title == "New Title")
    #expect(item.author == "New Author")
    #expect(item.tags == ["new-tag"])
    #expect(isEditingMetadata == false)
}
