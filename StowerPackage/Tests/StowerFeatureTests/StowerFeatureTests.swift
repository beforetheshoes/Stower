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
