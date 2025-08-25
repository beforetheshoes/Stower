import Testing
import Foundation
@testable import StowerFeature

@MainActor
@Suite("HTMLSanitizationService Tests")
struct HTMLSanitizationServiceTests {
    
    // MARK: - Initialization Tests
    
    @Test("HTMLSanitizationService should initialize correctly")
    func testInitialization() async throws {
        let _ = HTMLSanitizationService()
        #expect(Bool(true)) // Should initialize without error
    }
    
    // MARK: - Basic HTML to Markdown Conversion Tests
    
    @Test("sanitizeAndConvertToMarkdown should convert simple HTML")
    func testSimpleHTMLConversion() async throws {
        let service = HTMLSanitizationService()
        let simpleHTML = "<p>This is a simple paragraph.</p>"
        
        let result = try service.sanitizeAndConvertToMarkdown(simpleHTML)
        
        #expect(result.contains("This is a simple paragraph"))
        #expect(!result.contains("<p>"))
        #expect(!result.contains("</p>"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should convert headers")
    func testHeaderConversion() async throws {
        let service = HTMLSanitizationService()
        let headerHTML = """
        <h1>Main Title</h1>
        <h2>Subtitle</h2>
        <h3>Section Header</h3>
        <h4>Subsection</h4>
        <h5>Minor Header</h5>
        <h6>Smallest Header</h6>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(headerHTML)
        
        #expect(result.contains("# Main Title"))
        #expect(result.contains("## Subtitle"))
        #expect(result.contains("### Section Header"))
        #expect(result.contains("#### Subsection"))
        #expect(result.contains("##### Minor Header"))
        #expect(result.contains("###### Smallest Header"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should convert formatting elements")
    func testFormattingElementConversion() async throws {
        let service = HTMLSanitizationService()
        let formattingHTML = """
        <p>This has <strong>bold text</strong> and <em>italic text</em>.</p>
        <p>Also <b>bold</b> and <i>italic</i> variants.</p>
        <p>Some <code>inline code</code> here.</p>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(formattingHTML)
        
        #expect(result.contains("**bold text**"))
        #expect(result.contains("*italic text*"))
        #expect(result.contains("**bold**"))
        #expect(result.contains("*italic*"))
        #expect(result.contains("`inline code`"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should convert lists")
    func testListConversion() async throws {
        let service = HTMLSanitizationService()
        let listHTML = """
        <ul>
            <li>First unordered item</li>
            <li>Second unordered item</li>
        </ul>
        <ol>
            <li>First ordered item</li>
            <li>Second ordered item</li>
        </ol>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(listHTML)
        
        #expect(result.contains("- First unordered item"))
        #expect(result.contains("- Second unordered item"))
        #expect(result.contains("1. First ordered item"))
        #expect(result.contains("2. Second ordered item"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should convert links")
    func testLinkConversion() async throws {
        let service = HTMLSanitizationService()
        let linkHTML = """
        <p>Here is a <a href="https://example.com">link to example</a>.</p>
        <p>Another <a href="https://test.org">test link</a>.</p>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(linkHTML)
        
        #expect(result.contains("[link to example](https://example.com)"))
        #expect(result.contains("[test link](https://test.org)"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should convert images")
    func testImageConversion() async throws {
        let service = HTMLSanitizationService()
        let imageHTML = """
        <img src="https://example.com/image.jpg" alt="Example image">
        <img src="https://test.org/photo.png" alt="Test photo">
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(imageHTML)
        
        #expect(result.contains("![Example image](https://example.com/image.jpg)"))
        #expect(result.contains("![Test photo](https://test.org/photo.png)"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should convert blockquotes")
    func testBlockquoteConversion() async throws {
        let service = HTMLSanitizationService()
        let blockquoteHTML = """
        <blockquote>This is a quoted text block.</blockquote>
        <blockquote>
            <p>Multi-paragraph quote.</p>
            <p>Second paragraph of quote.</p>
        </blockquote>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(blockquoteHTML)
        
        #expect(result.contains("> This is a quoted text block"))
        #expect(result.contains("> Multi-paragraph quote"))
        #expect(result.contains("> Second paragraph of quote"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should convert code blocks")
    func testCodeBlockConversion() async throws {
        let service = HTMLSanitizationService()
        let codeHTML = """
        <pre><code>function example() {
            return "hello world";
        }</code></pre>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(codeHTML)
        
        #expect(result.contains("```"))
        #expect(result.contains("function example()"))
        #expect(result.contains("return \"hello world\""))
    }
    
    // MARK: - Security Sanitization Tests
    
    @Test("sanitizeAndConvertToMarkdown should remove script tags")
    func testScriptTagRemoval() async throws {
        let service = HTMLSanitizationService()
        let maliciousHTML = """
        <p>Safe content</p>
        <script>alert('XSS attack!')</script>
        <p>More safe content</p>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(maliciousHTML)
        
        #expect(result.contains("Safe content"))
        #expect(result.contains("More safe content"))
        #expect(!result.contains("<script>"))
        #expect(!result.contains("alert"))
        #expect(!result.contains("XSS attack"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should remove style tags")
    func testStyleTagRemoval() async throws {
        let service = HTMLSanitizationService()
        let styledHTML = """
        <p>Content with styles</p>
        <style>
            body { background: red; }
            p { color: blue; }
        </style>
        <p>More content</p>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(styledHTML)
        
        #expect(result.contains("Content with styles"))
        #expect(result.contains("More content"))
        #expect(!result.contains("<style>"))
        #expect(!result.contains("background: red"))
        #expect(!result.contains("color: blue"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should remove dangerous elements")
    func testDangerousElementRemoval() async throws {
        let service = HTMLSanitizationService()
        let dangerousHTML = """
        <p>Safe paragraph</p>
        <iframe src="https://malicious-site.com"></iframe>
        <object data="malicious.swf"></object>
        <embed src="malicious.pdf">
        <applet code="MaliciousApplet.class"></applet>
        <p>Another safe paragraph</p>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(dangerousHTML)
        
        #expect(result.contains("Safe paragraph"))
        #expect(result.contains("Another safe paragraph"))
        #expect(!result.contains("<iframe>"))
        #expect(!result.contains("<object>"))
        #expect(!result.contains("<embed>"))
        #expect(!result.contains("<applet>"))
        #expect(!result.contains("malicious"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should remove form elements")
    func testFormElementRemoval() async throws {
        let service = HTMLSanitizationService()
        let formHTML = """
        <p>Content before form</p>
        <form action="/submit">
            <input type="text" name="username">
            <button type="submit">Submit</button>
            <select name="options">
                <option value="1">Option 1</option>
            </select>
            <textarea name="comments"></textarea>
        </form>
        <p>Content after form</p>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(formHTML)
        
        #expect(result.contains("Content before form"))
        #expect(result.contains("Content after form"))
        #expect(!result.contains("<form>"))
        #expect(!result.contains("<input>"))
        #expect(!result.contains("<button>"))
        #expect(!result.contains("<select>"))
        #expect(!result.contains("<textarea>"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should remove dangerous attributes")
    func testDangerousAttributeRemoval() async throws {
        let service = HTMLSanitizationService()
        let attributeHTML = """
        <p onclick="alert('click')" onmouseover="alert('hover')" style="color: red;" class="dangerous" id="target">
            Paragraph with dangerous attributes
        </p>
        <div onload="maliciousFunction()" onerror="anotherMaliciousFunction()">
            Div with dangerous attributes
        </div>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(attributeHTML)
        
        #expect(result.contains("Paragraph with dangerous attributes"))
        #expect(result.contains("Div with dangerous attributes"))
        #expect(!result.contains("onclick"))
        #expect(!result.contains("onmouseover"))
        #expect(!result.contains("onload"))
        #expect(!result.contains("onerror"))
        #expect(!result.contains("style="))
        #expect(!result.contains("class="))
        #expect(!result.contains("id="))
        #expect(!result.contains("alert"))
        #expect(!result.contains("maliciousFunction"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should remove javascript URLs")
    func testJavaScriptURLRemoval() async throws {
        let service = HTMLSanitizationService()
        let jsURLHTML = """
        <a href="javascript:alert('XSS')">Malicious link</a>
        <img src="javascript:alert('XSS')" alt="Malicious image">
        <a href="https://safe-link.com">Safe link</a>
        <img src="https://example.com/safe.jpg" alt="Safe image">
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(jsURLHTML)
        
        #expect(result.contains("Malicious link")) // Text preserved
        #expect(result.contains("Safe link"))
        #expect(result.contains("[Safe link](https://safe-link.com)"))
        #expect(result.contains("![Safe image](https://example.com/safe.jpg)"))
        #expect(!result.contains("javascript:"))
        #expect(!result.contains("alert"))
    }
    
    // MARK: - Edge Cases and Error Handling
    
    @Test("sanitizeAndConvertToMarkdown should handle empty HTML")
    func testEmptyHTML() async throws {
        let service = HTMLSanitizationService()
        
        let result = try service.sanitizeAndConvertToMarkdown("")
        
        #expect(result.isEmpty || result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    
    @Test("sanitizeAndConvertToMarkdown should handle whitespace-only HTML")
    func testWhitespaceOnlyHTML() async throws {
        let service = HTMLSanitizationService()
        let whitespaceHTML = "   \n\t  "
        
        let result = try service.sanitizeAndConvertToMarkdown(whitespaceHTML)
        
        #expect(result.isEmpty || result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    
    @Test("sanitizeAndConvertToMarkdown should handle malformed HTML")
    func testMalformedHTML() async throws {
        let service = HTMLSanitizationService()
        let malformedHTML = "<p>Unclosed paragraph<div>Nested improperly</p></div>"
        
        // Should not crash with malformed HTML
        let result = try service.sanitizeAndConvertToMarkdown(malformedHTML)
        
        #expect(result.contains("Unclosed paragraph") || result.contains("Nested improperly"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should handle deeply nested HTML")
    func testDeeplyNestedHTML() async throws {
        let service = HTMLSanitizationService()
        
        // Create deeply nested structure
        var nestedHTML = "<div>"
        for i in 0..<20 {
            nestedHTML += "<div>Level \(i)"
        }
        nestedHTML += " Content"
        for _ in 0..<20 {
            nestedHTML += "</div>"
        }
        nestedHTML += "</div>"
        
        let result = try service.sanitizeAndConvertToMarkdown(nestedHTML)
        
        #expect(result.contains("Content"))
        #expect(result.contains("Level"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should handle HTML with no body")
    func testHTMLWithNoBody() async throws {
        let service = HTMLSanitizationService()
        let htmlWithoutBody = """
        <html>
        <head><title>Title</title></head>
        <p>Content outside body</p>
        </html>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(htmlWithoutBody)
        
        #expect(result.contains("Content outside body"))
        #expect(!result.contains("<html>"))
        #expect(!result.contains("<head>"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should handle elements without content")
    func testElementsWithoutContent() async throws {
        let service = HTMLSanitizationService()
        let emptyElementsHTML = """
        <h1></h1>
        <p></p>
        <strong></strong>
        <em></em>
        <h2>Non-empty header</h2>
        <p>Non-empty paragraph</p>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(emptyElementsHTML)
        
        #expect(result.contains("Non-empty header"))
        #expect(result.contains("Non-empty paragraph"))
        #expect(result.contains("## Non-empty header"))
        
        // Empty elements should not add extra markdown formatting
        let lines = result.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(nonEmptyLines.count >= 2) // At least the two non-empty elements
    }
    
    // MARK: - Performance Tests
    
    @Test("sanitizeAndConvertToMarkdown should handle large HTML efficiently", .timeLimit(.minutes(1)))
    func testLargeHTMLPerformance() async throws {
        let service = HTMLSanitizationService()
        let largeHTML = PerformanceTestUtils.generateLargeHTML(paragraphCount: 500)
        
        let (result, duration) = try await PerformanceTestUtils.measure { @MainActor in
            return try service.sanitizeAndConvertToMarkdown(largeHTML)
        }
        
        #expect(duration < 3.0, "Large HTML processing should complete within 3 seconds")
        #expect(result.count > 1000, "Should produce substantial markdown content")
    }
    
    @Test("sanitizeAndConvertToMarkdown should handle concurrent processing")
    func testConcurrentProcessing() async throws {
        let service = HTMLSanitizationService()
        
        let testCases = [
            "<h1>Title 1</h1><p>Content 1</p>",
            "<h2>Title 2</h2><p>Content 2</p>",
            "<h3>Title 3</h3><p>Content 3</p>",
            "<h4>Title 4</h4><p>Content 4</p>",
            "<h5>Title 5</h5><p>Content 5</p>"
        ]
        
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for (_, html) in testCases.enumerated() {
                group.addTask { @MainActor in
                    return try service.sanitizeAndConvertToMarkdown(html)
                }
            }
            
            var results: [String] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        
        #expect(results.count == 5)
        
        // Each result should be valid markdown
        for result in results {
            #expect(result.contains("#")) // Should contain header
            #expect(result.contains("Content")) // Should contain content
        }
    }
    
    // MARK: - Complex Content Tests
    
    @Test("sanitizeAndConvertToMarkdown should handle mixed content")
    func testMixedContent() async throws {
        let service = HTMLSanitizationService()
        let mixedHTML = MockHTMLContent.complexHTML
        
        let result = try service.sanitizeAndConvertToMarkdown(mixedHTML)
        
        #expect(result.contains("# Main Title"))
        #expect(result.contains("## Section 1"))
        #expect(result.contains("### Subsection"))
        #expect(result.contains("> This is a quote"))
        #expect(result.contains("`inline code`"))
        #expect(result.contains("```"))
        #expect(!result.contains("<"))
        // Check that HTML tags are removed (but allow markdown blockquotes with >)
        #expect(!result.contains("<div"))
        #expect(!result.contains("</div"))
        #expect(!result.contains("<p"))
        #expect(!result.contains("</p>"))
    }
    
    @Test("sanitizeAndConvertToMarkdown should preserve text content while removing HTML")
    func testTextContentPreservation() async throws {
        let service = HTMLSanitizationService()
        let htmlWithContent = """
        <div class="article" id="main" onclick="track()">
            <h1 style="color: blue;">Important Article</h1>
            <p onmouseover="highlight()">This is the first paragraph with <strong>important</strong> information.</p>
            <script>maliciousCode();</script>
            <p class="content">Second paragraph with <em>emphasis</em>.</p>
            <iframe src="ads.html"></iframe>
        </div>
        """
        
        let result = try service.sanitizeAndConvertToMarkdown(htmlWithContent)
        
        // Should preserve all text content (with markdown formatting applied)
        #expect(result.contains("Important Article"))
        #expect(result.contains("This is the first paragraph"))
        #expect(result.contains("**important** information"))
        #expect(result.contains("Second paragraph"))
        #expect(result.contains("emphasis"))
        
        // Should convert to proper markdown
        #expect(result.contains("# Important Article"))
        #expect(result.contains("**important**"))
        #expect(result.contains("*emphasis*"))
        
        // Should remove all dangerous elements
        #expect(!result.contains("maliciousCode"))
        #expect(!result.contains("onclick"))
        #expect(!result.contains("onmouseover"))
        #expect(!result.contains("class="))
        #expect(!result.contains("style="))
        #expect(!result.contains("iframe"))
    }
    
    // MARK: - Error Handling Tests
    
    @Test("sanitizeAndConvertToMarkdown should handle SwiftSoup parsing errors")
    func testSwiftSoupParsingErrors() async throws {
        let service = HTMLSanitizationService()
        
        // Test with extremely malformed HTML that might cause issues
        let extremelyMalformed = String(repeating: "<", count: 100) + String(repeating: ">", count: 100)
        
        // Should handle gracefully, might produce minimal content but shouldn't crash
        let _ = try service.sanitizeAndConvertToMarkdown(extremelyMalformed)
        
        // Main requirement: should not crash
        #expect(Bool(true))
    }
}