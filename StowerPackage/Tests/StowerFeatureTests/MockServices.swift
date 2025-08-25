import Foundation
import SwiftData
import Combine
import Testing
@testable import StowerFeature

// MARK: - Mock Network Session

@MainActor
public final class MockURLSession: @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [String: (Data?, URLResponse?, Error?)] = [:]
    private var _delay: TimeInterval = 0
    
    public init() {}
    
    public func setResponse(for urlString: String, data: Data?, response: URLResponse?, error: Error?) {
        lock.withLock {
            _responses[urlString] = (data, response, error)
        }
    }
    
    public func setDelay(_ delay: TimeInterval) {
        lock.withLock {
            _delay = delay
        }
    }
    
    public func data(from url: URL) async throws -> (Data, URLResponse) {
        let (mockData, mockResponse, mockError) = lock.withLock {
            (_responses[url.absoluteString], _delay)
        }.0 ?? (nil, nil, nil)
        
        // Simulate network delay if configured
        if lock.withLock({ _delay }) > 0 {
            try await Task.sleep(for: .seconds(lock.withLock({ _delay })))
        }
        
        if let error = mockError {
            throw error
        }
        
        let data = mockData ?? Data()
        let response = mockResponse ?? HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )!
        
        return (data, response)
    }
}

// MARK: - Mock File Manager

public final class MockFileManager: @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [String: Data] = [:]
    private var _directories: Set<String> = []
    
    public init() {}
    
    public func setFile(at path: String, content: Data) {
        lock.withLock {
            _files[path] = content
            // Auto-create parent directories
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            _directories.insert(dir)
        }
    }
    
    public func createDirectory(at path: String) {
        let _ = lock.withLock {
            _directories.insert(path)
        }
    }
    
    public func fileExists(atPath path: String) -> Bool {
        return lock.withLock { _files[path] != nil }
    }
    
    public func contents(atPath path: String) -> Data? {
        return lock.withLock { _files[path] }
    }
    
    public func removeItem(atPath path: String) throws {
        let _ = lock.withLock {
            _files.removeValue(forKey: path)
        }
    }
    
    public func directoryExists(atPath path: String) -> Bool {
        return lock.withLock { _directories.contains(path) }
    }
    
    public func clearAll() {
        lock.withLock {
            _files.removeAll()
            _directories.removeAll()
        }
    }
}

// MARK: - Mock PDF Data Generator

public struct MockPDFData {
    public static func validPDFHeader() -> Data {
        // Valid PDF magic bytes
        return Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]) // "%PDF-1.4"
    }
    
    public static func invalidPDFData() -> Data {
        return Data("This is not PDF data".utf8)
    }
    
    public static func emptyData() -> Data {
        return Data()
    }
    
    public static func minimalValidPDF() -> Data {
        let pdfContent = """
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /Contents 4 0 R >>
        endobj
        4 0 obj
        << /Length 44 >>
        stream
        BT
        /F1 12 Tf
        100 700 Td
        (Test PDF Content) Tj
        ET
        endstream
        endobj
        xref
        0 5
        0000000000 65535 f 
        0000000009 00000 n 
        0000000058 00000 n 
        0000000115 00000 n 
        0000000174 00000 n 
        trailer
        << /Size 5 /Root 1 0 R >>
        startxref
        267
        %%EOF
        """
        return Data(pdfContent.utf8)
    }
}

// MARK: - Mock Image Data Generator

public struct MockImageData {
    public static func validJPEGHeader() -> Data {
        // JPEG magic bytes
        return Data([0xFF, 0xD8, 0xFF, 0xE0])
    }
    
    public static func validPNGHeader() -> Data {
        // PNG magic bytes
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
    
    public static func minimalJPEG(width: Int = 100, height: Int = 100) -> Data {
        // This is a very basic JPEG structure - in real tests you might use actual image data
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header
        data.append(contentsOf: [0x00, 0x10]) // Length
        data.append(contentsOf: "JFIF".utf8)
        data.append(contentsOf: Array(repeating: 0x00, count: 100)) // Minimal JPEG body
        data.append(contentsOf: [0xFF, 0xD9]) // JPEG end
        return data
    }
    
    public static func invalidImageData() -> Data {
        return Data("Not an image".utf8)
    }
}

// MARK: - Test Data Factories

public struct TestDataFactory {
    public static func createSavedItem(
        title: String = "Test Article",
        url: URL? = URL(string: "https://example.com/article"),
        markdown: String = "# Test Content\n\nThis is test content.",
        tags: [String] = ["test"],
        author: String = "Test Author"
    ) -> SavedItem {
        return SavedItem(
            url: url,
            title: title,
            author: author,
            extractedMarkdown: markdown,
            tags: tags
        )
    }
    
    public static func createImageDownloadSettings(
        globalAutoDownload: Bool = true,
        alwaysDomains: [String] = [],
        neverDomains: [String] = [],
        askForNew: Bool = false,
        maxSizeKB: Int = 5000,
        downloadOnCellular: Bool = false
    ) -> ImageDownloadSettings {
        return ImageDownloadSettings(
            globalAutoDownload: globalAutoDownload,
            alwaysDownloadDomains: alwaysDomains,
            neverDownloadDomains: neverDomains,
            askForNewDomains: askForNew,
            maxImageSizeKB: maxSizeKB,
            downloadOnCellular: downloadOnCellular
        )
    }
    
    public static func createSavedImageRef(
        url: String = "https://example.com/image.jpg",
        width: Int = 800,
        height: Int = 600,
        origin: ImageOrigin = .web,
        format: String = "jpg"
    ) -> SavedImageRef {
        return SavedImageRef(
            sourceURL: URL(string: url),
            width: width,
            height: height,
            origin: origin,
            fileFormat: format
        )
    }
    
    public static func createSavedImageAsset(
        imageData: Data = MockImageData.minimalJPEG(),
        width: Int = 800,
        height: Int = 600,
        origin: ImageOrigin = .web,
        format: String = "jpg",
        altText: String = ""
    ) -> SavedImageAsset {
        return SavedImageAsset(
            imageData: imageData,
            width: width,
            height: height,
            origin: origin,
            fileFormat: format,
            altText: altText
        )
    }
}

// MARK: - Test HTML Content

public struct MockHTMLContent {
    public static let simpleArticle = """
    <html>
    <head><title>Test Article</title></head>
    <body>
        <article>
            <h1>Test Article Title</h1>
            <p>This is the first paragraph of the article.</p>
            <p>This is the second paragraph with <strong>bold text</strong>.</p>
            <img src="https://example.com/image.jpg" alt="Test image">
            <ul>
                <li>First list item</li>
                <li>Second list item</li>
            </ul>
        </article>
    </body>
    </html>
    """
    
    public static let maliciousHTML = """
    <html>
    <head><title>Malicious Content</title></head>
    <body>
        <p>Safe content</p>
        <script>alert('XSS attack!')</script>
        <img src="javascript:alert('XSS')" alt="Malicious image">
        <a href="javascript:alert('XSS')">Malicious link</a>
        <iframe src="javascript:alert('XSS')"></iframe>
        <object data="javascript:alert('XSS')"></object>
    </body>
    </html>
    """
    
    public static let complexHTML = """
    <html>
    <head>
        <title>Complex Article</title>
        <meta name="author" content="Test Author">
        <meta name="description" content="Test description">
    </head>
    <body>
        <header>
            <h1>Main Title</h1>
            <div class="author">By Test Author</div>
        </header>
        <main>
            <article>
                <h2>Section 1</h2>
                <p>Paragraph with <a href="https://example.com">link</a>.</p>
                <blockquote>This is a quote</blockquote>
                <h3>Subsection</h3>
                <code>inline code</code>
                <pre><code>
                function example() {
                    return "code block";
                }
                </code></pre>
                <table>
                    <tr><td>Cell 1</td><td>Cell 2</td></tr>
                </table>
            </article>
        </main>
    </body>
    </html>
    """
    
    public static let emptyHTML = ""
    
    public static let malformedHTML = "<html><p>Unclosed paragraph<div>Nested improperly</p></div>"
}

// MARK: - In-Memory Model Context Helper

public extension ModelContainer {
    @MainActor
    static func inMemoryContainer() throws -> ModelContainer {
        return try ModelContainer(
            for: SavedItem.self, ImageDownloadSettings.self, SavedImageRef.self, SavedImageAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}

public extension ModelContext {
    @MainActor
    static func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer.inMemoryContainer()
        return ModelContext(container)
    }
}

// MARK: - Test Assertions

public struct TestAssertions {
    public static func assertImageDownloadDecision(
        _ decision: ImageDownloadDecision,
        expectedShouldDownload: Bool,
        expectedShouldAsk: Bool = false,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #expect(decision.shouldDownload == expectedShouldDownload, "Expected shouldDownload: \(expectedShouldDownload), got: \(decision.shouldDownload)", sourceLocation: Testing.SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: Int(line), column: 1))
        #expect(decision.shouldAsk == expectedShouldAsk, "Expected shouldAsk: \(expectedShouldAsk), got: \(decision.shouldAsk)", sourceLocation: Testing.SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: Int(line), column: 1))
    }
}

// MARK: - Performance Testing Utilities

public struct PerformanceTestUtils {
    public static func measure<T>(operation: @Sendable () async throws -> T) async rethrows -> (result: T, duration: TimeInterval) {
        let startTime = Date()
        let result = try await operation()
        let duration = Date().timeIntervalSince(startTime)
        return (result, duration)
    }
    
    public static func generateLargeText(wordCount: Int = 1000) -> String {
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do"]
        return (0..<wordCount).map { _ in words.randomElement()! }.joined(separator: " ")
    }
    
    public static func generateLargeHTML(paragraphCount: Int = 100) -> String {
        let paragraphs = (0..<paragraphCount).map { i in
            "<p>Paragraph \(i + 1): \(generateLargeText(wordCount: 50))</p>"
        }
        return "<html><body>\(paragraphs.joined())</body></html>"
    }
}