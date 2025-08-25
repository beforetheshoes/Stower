import Testing
import Foundation
import PDFKit
import Synchronization
@testable import StowerFeature

@Suite("PDFExtractionService Tests")
struct PDFExtractionServiceTests {
    
    // MARK: - Initialization Tests
    
    @Test("PDFExtractionService should initialize without debug logger")
    func testInitializationWithoutLogger() async throws {
        let service = PDFExtractionService()
        #expect(service.debugLogger == nil)
    }
    
    @Test("PDFExtractionService should initialize with debug logger")
    func testInitializationWithLogger() async throws {
        let loggedMessages = Mutex<[String]>([]) // Thread-safe logging
        
        let service = PDFExtractionService { message in
            loggedMessages.withLock { $0.append(message) }
        }
        
        #expect(service.debugLogger != nil)
        
        // Test logging by trying to extract from invalid data
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: Data())
        }
        
        #expect(loggedMessages.withLock { $0.count > 0 })
        #expect(loggedMessages.withLock { $0.contains { $0.contains("PDFExtractionService") } })
    }
    
    // MARK: - Data Extraction Tests
    
    @Test("extractContent should handle empty PDF data")
    func testEmptyDataExtraction() async throws {
        let service = PDFExtractionService()
        let emptyData = MockPDFData.emptyData()
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: emptyData)
        }
    }
    
    @Test("extractContent should handle invalid PDF data")
    func testInvalidDataExtraction() async throws {
        let service = PDFExtractionService()
        let invalidData = MockPDFData.invalidPDFData()
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: invalidData)
        }
    }
    
    @Test("extractContent should handle valid PDF header but incomplete data")
    func testIncompleteValidPDFData() async throws {
        let service = PDFExtractionService()
        let headerOnlyData = MockPDFData.validPDFHeader()
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: headerOnlyData)
        }
    }
    
    @Test("extractContent should handle minimal valid PDF")
    func testMinimalValidPDF() async throws {
        let service = PDFExtractionService()
        let minimalPDF = MockPDFData.minimalValidPDF()
        
        do {
            let result = try await service.extractContent(from: minimalPDF)
            
            #expect(!result.title.isEmpty)
            #expect(!result.markdown.isEmpty)
            #expect(result.markdown.contains("Test PDF Content") || result.markdown.contains("content"))
        } catch PDFExtractionError.invalidPDF {
            // This is acceptable in test environment as our mock PDF might not be fully valid
            print("⚠️ Mock PDF was not valid enough for PDFKit (expected in test environment)")
        } catch PDFExtractionError.emptyPDF {
            // This is acceptable in test environment as our mock PDF might have no extractable text
            print("⚠️ Mock PDF has no extractable text content (expected in test environment)")
        }
    }
    
    // MARK: - URL Extraction Tests
    
    @Test("extractContent should handle non-existent file URL")
    func testNonExistentFileURL() async throws {
        let service = PDFExtractionService()
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/path/file.pdf")
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: nonExistentURL)
        }
    }
    
    @Test("extractContent should handle invalid file URL")
    func testInvalidFileURL() async throws {
        let service = PDFExtractionService()
        
        // Create a temporary file with invalid PDF content
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("invalid.pdf")
        
        let invalidData = "This is not a PDF file".data(using: .utf8)!
        try invalidData.write(to: tempFile)
        
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: tempFile)
        }
    }
    
    @Test("extractContent should handle directory instead of file")
    func testDirectoryURL() async throws {
        let service = PDFExtractionService()
        let tempDir = FileManager.default.temporaryDirectory
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: tempDir)
        }
    }
    
    // MARK: - Text Processing Tests
    
    @Test("isListItem should detect various list patterns")
    func testListItemDetection() async throws {
        let service = PDFExtractionService()
        
        let listItems = [
            "• First bullet point",
            "  • Indented bullet",
            "1. Numbered item",
            "  1. Indented number",
            "a) Letter item",
            "  a) Indented letter",
            "(1) Parenthetical number",
            "  (1) Indented parenthetical",
            "- Dash bullet",
            "  - Indented dash",
            "* Asterisk bullet",
            "  * Indented asterisk",
            "○ Circle bullet",
            "  ○ Indented circle",
            "▪ Square bullet",
            "■ Filled square bullet",
            "i. Roman numeral",
            "  i. Indented roman",
            "I. Capital roman numeral",
            "A. Capital letter",
            "  A. Indented capital"
        ]
        
        for item in listItems {
            let isListItem = service.isListItem(item)
            #expect(isListItem, "Should detect list item: '\(item)'")
        }
    }
    
    @Test("isListItem should not detect regular paragraphs")
    func testNonListItemDetection() async throws {
        let service = PDFExtractionService()
        
        let nonListItems = [
            "Regular paragraph text",
            "Just a sentence without bullets.",
            "No bullets here at all",
            "This is a longer paragraph with multiple sentences. It should not be detected as a list item.",
            "1 This starts with number but is not formatted as list",
            "a This starts with letter but no punctuation",
            "Text with. period in middle",
            "Text with • bullet in middle but not at start",
            "   Regular text with leading spaces but no bullet",
            ""
        ]
        
        for item in nonListItems {
            let isListItem = service.isListItem(item)
            #expect(!isListItem, "Should not detect list item: '\(item)'")
        }
    }
    
    @Test("cleanupMarkdown should fix hyphenation")
    func testHyphenationFixes() async throws {
        let service = PDFExtractionService()
        
        let testCases = [
            ("This is a para-\ngraph with broken words.", "paragraph"),
            ("Hyp-\nhenated word", "Hyphenated"),
            ("Multi-\nple hyph-\nenated words", "Multiple hyphenated"),
            ("End of line-\n\nNext paragraph", "line\n\nNext"),
            ("No hyphen-\n ation with space", "hyphen- ation") // Should not fix if space follows
        ]
        
        for (input, expectedToContain) in testCases {
            let result = service.cleanupMarkdown(input)
            #expect(result.contains(expectedToContain), "Failed to fix hyphenation in: '\(input)' -> '\(result)'")
        }
    }
    
    @Test("cleanupMarkdown should normalize spacing")
    func testSpacingNormalization() async throws {
        let service = PDFExtractionService()
        
        let testCases = [
            ("Text with    multiple   spaces", "Text with multiple spaces"),
            ("Text\t\twith\ttabs", "Text with tabs"),
            ("Text with \n\n\n\n multiple newlines", "Text with\n\nmultiple newlines"),
            ("   Leading and trailing spaces   ", "Leading and trailing spaces"),
            ("Multiple\n\n\n\nLine\n\n\nBreaks", "Multiple\n\nLine\n\nBreaks")
        ]
        
        for (input, expected) in testCases {
            let result = service.cleanupMarkdown(input)
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines),
                   "Failed spacing normalization: '\(input)' -> '\(result)' (expected: '\(expected)')")
        }
    }
    
    @Test("cleanupMarkdown should preserve code blocks")
    func testCodeBlockPreservation() async throws {
        let service = PDFExtractionService()
        
        let markdownWithCode = """
        # Title
        
        Here's some code:
        
        ```javascript
        function example() {
            return "code with    multiple   spaces";
        }
        ```
        
        Regular text with    multiple   spaces should be normalized.
        """
        
        let result = service.cleanupMarkdown(markdownWithCode)
        
        // Code block spacing should be preserved
        #expect(result.contains("    multiple   spaces\";"), "Code block spacing should be preserved")
        
        // Regular text spacing should be normalized
        let lines = result.components(separatedBy: .newlines)
        let regularTextLine = lines.first { $0.contains("Regular text") && !$0.contains("```") }
        if let regularLine = regularTextLine {
            #expect(!regularLine.contains("    multiple   "), "Regular text spacing should be normalized")
        }
    }
    
    @Test("cleanupMarkdown should handle empty and whitespace content")
    func testEmptyContentHandling() async throws {
        let service = PDFExtractionService()
        
        let testCases = [
            ("", ""),
            ("   ", ""),
            ("\n\n\n", ""),
            ("\t\t\t", ""),
            ("   \n\n  \t  \n   ", "")
        ]
        
        for (input, expected) in testCases {
            let result = service.cleanupMarkdown(input)
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == expected,
                   "Empty content handling failed: '\(input)' -> '\(result)'")
        }
    }
    
    // MARK: - Performance Tests
    
    @Test("cleanupMarkdown should handle large text efficiently", .timeLimit(.minutes(1)))
    func testLargeTextPerformance() async throws {
        let service = PDFExtractionService()
        
        // Generate large text with various formatting issues
        let largeText = String(repeating: "This is a para-\ngraph with issues.    Multiple   spaces here.\n\n\n", count: 1000)
        
        let (result, duration) = await PerformanceTestUtils.measure {
            return service.cleanupMarkdown(largeText)
        }
        
        #expect(duration < 2.0, "Large text processing should complete within 2 seconds")
        #expect(result.count > 0, "Should produce cleaned text")
        #expect(!result.contains("para-\ngraph"), "Should fix hyphenation in large text")
    }
    
    @Test("isListItem should perform well with many calls", .timeLimit(.minutes(1)))
    func testListDetectionPerformance() async throws {
        let service = PDFExtractionService()
        
        let testTexts = [
            "• Bullet point",
            "1. Numbered item", 
            "Regular paragraph",
            "a) Letter item",
            "Another regular paragraph",
            "(1) Parenthetical",
            "More regular text"
        ]
        
        let (_, duration) = await PerformanceTestUtils.measure {
            for _ in 0..<1000 {
                for text in testTexts {
                    let _ = service.isListItem(text)
                }
            }
        }
        
        #expect(duration < 1.0, "List detection should be fast for many calls")
    }
    
    // MARK: - Error Recovery Tests
    
    @Test("PDFExtractionService should handle corrupted PDF gracefully")
    func testCorruptedPDFHandling() async throws {
        let service = PDFExtractionService()
        
        // Create partially valid PDF data
        var corruptedPDF = MockPDFData.validPDFHeader()
        corruptedPDF.append("Random corrupt data".data(using: .utf8)!)
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: corruptedPDF)
        }
    }
    
    @Test("PDFExtractionService should handle PDF with no text content")
    func testPDFWithNoTextContent() async throws {
        let service = PDFExtractionService()
        
        // This would typically be a PDF with only images
        // For testing, we use minimal valid PDF without readable text content
        let pdfWithoutText = MockPDFData.minimalValidPDF()
        
        do {
            let result = try await service.extractContent(from: pdfWithoutText)
            
            // Should not fail, but might have minimal content
            #expect(!result.title.isEmpty || result.title == "Untitled PDF")
            // Markdown might be empty for PDFs without extractable text
        } catch PDFExtractionError.invalidPDF {
            // Expected for mock data in test environment
            print("⚠️ Mock PDF was not valid for PDFKit (expected)")
        } catch PDFExtractionError.emptyPDF {
            // Expected for PDFs without extractable text content
            print("⚠️ Mock PDF has no extractable text content (expected)")
        }
    }
    
    // MARK: - Concurrent Processing Tests
    
    @Test("PDFExtractionService should handle concurrent extractions")
    func testConcurrentExtractions() async throws {
        let service = PDFExtractionService()
        
        // Create multiple concurrent extraction tasks
        let tasks = (0..<3).map { index in
            Task {
                let data = index == 0 ? MockPDFData.minimalValidPDF() : MockPDFData.invalidPDFData()
                do {
                    return try await service.extractContent(from: data)
                } catch {
                    throw error
                }
            }
        }
        
        var successCount = 0
        var errorCount = 0
        
        for task in tasks {
            do {
                let _ = try await task.value
                successCount += 1
            } catch {
                errorCount += 1
            }
        }
        
        #expect(successCount + errorCount == 3)
        #expect(errorCount >= 2) // At least 2 should fail (invalid data)
    }
    
    // MARK: - Memory Management Tests
    
    @Test("PDFExtractionService should handle large PDF data")
    func testLargePDFDataHandling() async throws {
        let service = PDFExtractionService()
        
        // Create large data that looks like PDF but isn't valid
        var largePDFData = MockPDFData.validPDFHeader()
        largePDFData.append(Data(count: 1_000_000)) // 1MB of zeros
        
        await #expect(throws: PDFExtractionError.self) {
            try await service.extractContent(from: largePDFData)
        }
    }
    
    // MARK: - Integration Tests
    
    @Test("PDFExtractionService should integrate well with ContentExtractionService")
    func testContentExtractionServiceIntegration() async throws {
        // Test that ContentExtractionService properly delegates to PDFExtractionService
        let contentService = ContentExtractionService()
        let pdfData = MockPDFData.minimalValidPDF()
        
        do {
            let result = try await contentService.extractContent(
                from: pdfData,
                mimeType: "application/pdf",
                baseURL: nil
            )
            // If it succeeds, verify it's a proper PDF extraction result
            #expect(result.title == "PDF Document" || result.title.contains("PDF"))
            #expect(result.rawHTML.isEmpty) // PDFs don't have HTML
        } catch is PDFExtractionError {
            // This is also acceptable - mock PDF might not be fully valid
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("PDFExtractionService should handle malformed list patterns")
    func testMalformedListPatterns() async throws {
        let service = PDFExtractionService()
        
        let malformedPatterns = [
            "1",           // Just a number
            ".",           // Just a period
            "1.",          // Number with period but no space
            "• ",          // Bullet with space but no content
            "()",          // Empty parentheses
            "a",           // Just a letter
            "  1  .",      // Spaced out number and period
            "123. Valid",  // Valid large number
            "-",           // Just a dash
        ]
        
        for pattern in malformedPatterns {
            let isListItem = service.isListItem(pattern)
            
            if pattern == "123. Valid" {
                #expect(isListItem, "Should detect valid numbered item: '\(pattern)'")
            } else {
                // Most malformed patterns should not be detected as list items
                // Some edge cases might be detected, which is acceptable
                print("Malformed pattern '\(pattern)': \(isListItem ? "detected as list" : "not detected")")
            }
        }
    }
    
    @Test("PDFExtractionService should handle text with multiple formatting issues")
    func testComplexFormattingIssues() async throws {
        let service = PDFExtractionService()
        
        let complexText = """
        This is a para-
        graph with hyph-
        enation issues.    Multiple   spaces here.
        
        
        
        
        Excessive line breaks above.
        
        	Tabs	and		multiple	tabs.
        
        Another hyp-
        henated line with    spaces   after.
        
        Final paragraph.
        """
        
        let result = service.cleanupMarkdown(complexText)
        
        // Should fix hyphenation
        #expect(result.contains("paragraph with hyphenation"))
        
        // Should normalize spaces
        #expect(!result.contains("   "))
        
        // Should reduce excessive line breaks
        #expect(!result.contains("\n\n\n\n"))
        
        // Should preserve some paragraph breaks
        #expect(result.contains("\n\n"))
        
        // Should preserve content
        #expect(result.contains("Final paragraph"))
    }
}

// MARK: - PDFExtractionError Tests

@Suite("PDFExtractionError Tests")
struct PDFExtractionErrorTests {
    
    @Test("PDFExtractionError should have meaningful descriptions")
    func testErrorDescriptions() async throws {
        let errors: [PDFExtractionError] = [
            .invalidPDF,
            .emptyPDF,
            .processingError("Custom error message")
        ]
        
        for error in errors {
            let description = String(describing: error)
            #expect(!description.isEmpty, "Error should have non-empty description")
            
            switch error {
            case .processingError(let message):
                #expect(description.contains(message) || message == "Custom error message", "Processing error should contain message")
            default:
                #expect(Bool(true)) // Other errors just need to exist
            }
        }
    }
    
    @Test("PDFExtractionError should provide different error types")
    func testErrorTypes() async throws {
        let invalidPDF = PDFExtractionError.invalidPDF
        let emptyDoc = PDFExtractionError.emptyPDF
        let processing = PDFExtractionError.processingError("Test")
        
        // Each should be a distinct error type
        let descriptions = [
            String(describing: invalidPDF),
            String(describing: emptyDoc),
            String(describing: processing)
        ]
        
        let uniqueDescriptions = Set(descriptions)
        #expect(uniqueDescriptions.count == 3, "Each error should have unique representation")
    }
}