import Foundation
import SwiftSoup

// Remove @MainActor to allow CPU-heavy parsing off main thread  
public final class ContentExtractionService: Sendable {
    public let debugLogger: (@Sendable (String) -> Void)?
    
    public init(debugLogger: (@Sendable (String) -> Void)? = nil) {
        self.debugLogger = debugLogger
    }
    
    private func log(_ message: String) {
        debugLogger?(message)
    }
    
    public func extractContent(from html: String, baseURL: URL?) async throws -> ExtractedContent {
        // Check if this is actually PDF content (sometimes URLs redirect to PDFs)
        if let baseURL = baseURL, isPDFURL(baseURL.absoluteString) {
            self.log("📄 Detected PDF URL, using PDF extraction service")
            let pdfService = PDFExtractionService(debugLogger: debugLogger)
            return try await pdfService.extractContent(from: baseURL)
        }
        
        // Move CPU-heavy parsing off main thread using Task.detached
        return try await Task.detached {
            // TODO: Re-enable Foundation Models once beta issues are resolved
            // Temporarily disable Foundation Models due to crashes in iOS 26 beta
            self.log("🤖 Foundation Models temporarily disabled due to beta instability, using traditional extraction")
            
            // Try traditional SwiftSoup-based extraction first
            let traditionalResult = try self.extractContentTraditional(from: html, baseURL: baseURL)
            
            self.log("🔍 Traditional extraction result: \(traditionalResult.markdown.count) characters")
            
            // If traditional extraction yields very little content (likely JavaScript-rendered site),
            // fall back to WebView-based extraction
            if traditionalResult.markdown.count < 100 && baseURL != nil {
                self.log("⚠️ Traditional extraction yielded only \(traditionalResult.markdown.count) characters, trying WebView extraction")
                // Switch to main actor for WebView operations
                return try await Task { @MainActor in
                    try await self.extractContentWithWebView(url: baseURL!)
                }.value
            }
            
            self.log("✅ Using traditional extraction result (\(traditionalResult.markdown.count) characters)")
            return traditionalResult
        }.value
    }
    
    public func extractContent(from data: Data, mimeType: String?, baseURL: URL?) async throws -> ExtractedContent {
        // Check if this is PDF data
        if let mimeType = mimeType, mimeType == "application/pdf" {
            self.log("📄 Detected PDF data, using PDF extraction service")
            let pdfService = PDFExtractionService(debugLogger: debugLogger)
            return try await pdfService.extractContent(from: data)
        }
        
        // Check PDF magic bytes as fallback
        if data.count >= 4 {
            let pdfHeader = data.prefix(4)
            if pdfHeader == Data([0x25, 0x50, 0x44, 0x46]) { // "%PDF"
                self.log("📄 Detected PDF by magic bytes, using PDF extraction service")
                let pdfService = PDFExtractionService(debugLogger: debugLogger)
                return try await pdfService.extractContent(from: data)
            }
        }
        
        // Convert data to string and process as HTML
        guard let htmlString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ContentExtractionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert data to string"])
        }
        
        return try await extractContent(from: htmlString, baseURL: baseURL)
    }
    
    private func isPDFURL(_ urlString: String) -> Bool {
        return urlString.lowercased().hasSuffix(".pdf")
    }
    
    @MainActor
    private func extractContentWithWebView(url: URL) async throws -> ExtractedContent {
        log("🌐 Starting WebView-based content extraction for: \(url.absoluteString)")
        
        let extractor = WebViewContentExtractor()
        extractor.debugLogger = debugLogger
        let renderedHTML = try await extractor.extractRenderedHTML(from: url)
        
        log("✅ WebView extraction completed, processing \(renderedHTML.count) characters of rendered HTML")
        
        // Now use traditional extraction on the fully-rendered HTML
        return try extractContentTraditional(from: renderedHTML, baseURL: url)
    }
    
    
    private func extractContentTraditional(from html: String, baseURL: URL?) throws -> ExtractedContent {
        log("🔍 ContentExtractionService: Starting extraction for URL: \(baseURL?.absoluteString ?? "unknown")")
        log("📄 HTML length: \(html.count) characters")
        
        let document = try SwiftSoup.parse(html)
        
        // Debug: Check body content
        let bodyText: String
        if let body = document.body() {
            bodyText = try body.text()
            log("🔍 Body element text length: \(bodyText.count) characters")
            log("🔍 Body children count: \(body.children().count)")
            if bodyText.count > 100 {
                log("🔍 First 200 chars of body: '\(String(bodyText.prefix(200)))'")
            }
        } else {
            log("❌ No body element found!")
            bodyText = ""
        }
        
        // Extract title
        let title = try extractTitle(from: document, fallbackURL: baseURL)
        log("📝 Extracted title: '\(title)'")
        
        // Clean HTML by removing noise
        let cleanedDocument = try cleanHTML(document)
        
        // Debug: Check what cleaning did to the content
        if let cleanedBody = cleanedDocument.body() {
            let cleanedBodyText = try cleanedBody.text()
            log("🔍 After cleaning: body has \(cleanedBodyText.count) characters")
            log("🔍 Cleaning threshold: \(bodyText.count / 10) characters")
            if cleanedBodyText.count < bodyText.count / 10 || (bodyText.count > 1000 && cleanedBodyText.count < 100) {
                log("⚠️ Cleaning removed significant content! (\(bodyText.count) -> \(cleanedBodyText.count))")
                log("🔧 Using original document instead of cleaned version")
                // Find main content using original document if cleaning was too aggressive
                let mainContent = try findMainContent(in: document)
                log("🎯 Main content tag: \(mainContent.tagName())")
                let mainContentText = try mainContent.text()
                log("📊 Main content text length: \(mainContentText.count) characters")
                log("🔍 Main content preview: '\(String(mainContentText.prefix(200)))'")
                
                // Convert to markdown
                let markdown = try convertToMarkdown(mainContent, baseURL: baseURL)
                log("✅ Markdown length: \(markdown.count) characters")
                log("📖 First 200 chars of markdown: '\(String(markdown.prefix(200)))'")
                
                // Extract images
                let images = try extractImages(from: mainContent, baseURL: baseURL)
                log("🖼️ Found \(images.count) images")
                
                return ExtractedContent(
                    title: title,
                    markdown: markdown,
                    images: images,
                    rawHTML: try document.html()
                )
            }
        } else {
            log("❌ No body element found after cleaning!")
            log("🔧 Cleaning completely removed body element, using original document")
            // Find main content using original document if cleaning removed the body
            let mainContent = try findMainContent(in: document)
            log("🎯 Main content tag: \(mainContent.tagName())")
            let mainContentText = try mainContent.text()
            log("📊 Main content text length: \(mainContentText.count) characters")
            log("🔍 Main content preview: '\(String(mainContentText.prefix(200)))'")
            
            // Convert to markdown
            let markdown = try convertToMarkdown(mainContent, baseURL: baseURL)
            log("✅ Markdown length: \(markdown.count) characters")
            log("📖 First 200 chars of markdown: '\(String(markdown.prefix(200)))'")
            
            // Extract images
            let images = try extractImages(from: mainContent, baseURL: baseURL)
            log("🖼️ Found \(images.count) images")
            
            return ExtractedContent(
                title: title,
                markdown: markdown,
                images: images,
                rawHTML: try document.html()
            )
        }
        
        // Find main content using text density algorithm
        let mainContent = try findMainContent(in: cleanedDocument)
        log("🎯 Main content tag: \(mainContent.tagName())")
        let mainContentText = try mainContent.text()
        log("📊 Main content text length: \(mainContentText.count) characters")
        log("🔍 Main content preview: '\(String(mainContentText.prefix(200)))'")
        
        // Convert to markdown, including header content if present
        var markdown = ""
        
        // Check for header content and include it
        if let header = try document.select("header").first() {
            let headerMarkdown = try convertToMarkdown(header, baseURL: baseURL)
            if !headerMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += headerMarkdown + "\n\n"
                log("📰 Included header content: \(headerMarkdown.count) characters")
            }
        }
        
        // Add main content
        let mainMarkdown = try convertToMarkdown(mainContent, baseURL: baseURL)
        markdown += mainMarkdown
        
        log("✅ Markdown length: \(markdown.count) characters")
        log("📖 First 200 chars of markdown: '\(String(markdown.prefix(200)))'")
        
        // Extract images from both header and main content
        var images = try extractImages(from: mainContent, baseURL: baseURL)
        if let header = try document.select("header").first() {
            let headerImages = try extractImages(from: header, baseURL: baseURL)
            images.append(contentsOf: headerImages)
        }
        log("🖼️ Found \(images.count) images")
        
        return ExtractedContent(
            title: title,
            markdown: markdown,
            images: images,
            rawHTML: try document.html()
        )
    }
    
    // MARK: - Title Extraction
    
    private func extractTitle(from document: Document, fallbackURL: URL?) throws -> String {
        // Try title tag first
        if let titleElement = try document.select("title").first() {
            let title = try titleElement.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        
        // Try Open Graph title
        if let ogTitle = try document.select("meta[property=og:title]").first() {
            let title = try ogTitle.attr("content").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        
        // Try first h1
        if let h1 = try document.select("h1").first() {
            let title = try h1.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        
        // Fallback to URL host
        return fallbackURL?.host() ?? "Untitled"
    }
    
    // MARK: - HTML Cleaning
    
    private func cleanHTML(_ document: Document) throws -> Document {
        // Create a copy to avoid modifying the original
        let cleanedDocument = try SwiftSoup.parse(try document.html())
        
        // Remove unwanted elements
        let unwantedSelectors = [
            "script", "style", "nav", "header", "footer", "aside",
            ".ad", ".ads", ".advertisement", ".sponsored", ".popup",
            ".sidebar", ".social", ".comments", ".related",
            "[role=banner]", "[role=navigation]", "[role=complementary]"
        ]
        
        for selector in unwantedSelectors {
            try cleanedDocument.select(selector).remove()
        }
        
        // Remove elements with suspicious class/id names
        let suspiciousPatterns = [
            "[class*=ad]", "[id*=ad]", "[class*=sponsor]", "[id*=sponsor]",
            "[class*=popup]", "[id*=popup]", "[class*=overlay]", "[id*=overlay]"
        ]
        
        for pattern in suspiciousPatterns {
            try cleanedDocument.select(pattern).remove()
        }
        
        return cleanedDocument
    }
    
    // MARK: - Main Content Detection
    
    private func findMainContent(in document: Document) throws -> Element {
        log("🎯 Starting main content detection...")
        
        // First, try semantic HTML5 elements
        let semanticSelectors = ["article", "main", "[role=main]", ".content", ".post", ".entry"]
        
        for selector in semanticSelectors {
            if let element = try document.select(selector).first() {
                let textLength = try element.text().count
                if textLength > 100 { // Minimum content threshold
                    log("✅ Found semantic content: \(selector) with \(textLength) characters")
                    return element
                }
                log("⏭️ Skipping \(selector) - only \(textLength) characters")
            } else {
                log("❌ No elements found for selector: \(selector)")
            }
        }
        
        // Try common content patterns
        let contentSelectors = [
            ".post-content", ".article-content", ".entry-content", 
            ".story-body", ".article-body", ".post-body",
            "#content", "#main", "#post",
            // Ghost blog specific selectors
            ".gh-content", ".post-full-content", ".kg-card-markdown"
        ]
        
        for selector in contentSelectors {
            if let element = try document.select(selector).first() {
                let textLength = try element.text().count
                if textLength > 100 {
                    log("✅ Found content pattern: \(selector) with \(textLength) characters")
                    return element
                }
                log("⏭️ Skipping \(selector) - only \(textLength) characters")
            } else {
                log("❌ No elements found for selector: \(selector)")
            }
        }
        
        // If no semantic elements, use improved text density algorithm
        log("🔍 Falling back to text density algorithm...")
        return try findContentByTextDensity(in: document)
    }
    
    private func findContentByTextDensity(in document: Document) throws -> Element {
        let bodyElement = document.body() ?? document
        
        // Debug: Check if body itself should be a candidate
        let bodyText = try bodyElement.text()
        log("🔍 Body element has \(bodyText.count) characters")
        
        // Debug: Check what document we're working with
        if bodyText.count < 100 {
            log("⚠️ Body element unexpectedly small in text density algorithm!")
            log("🔍 Body children in density algorithm: \(bodyElement.children().count)")
            if bodyElement.children().count > 0 {
                let firstChild = bodyElement.children().first()!
                log("🔍 First child tag: \(firstChild.tagName())")
                log("🔍 First child text: \(try firstChild.text().count) characters")
            }
        }
        
        // More comprehensive candidate selection - try broader selector first
        var candidates = try bodyElement.select("div, section, article, p, main, span, aside")
        
        // Add body element as a candidate if it has substantial content
        if bodyText.count > 100 {
            log("🔍 Adding body element as candidate")
            var mutableCandidates = Array(candidates)
            mutableCandidates.insert(bodyElement, at: 0)
            candidates = Elements(mutableCandidates)
        }
        
        // If we get no candidates, get ALL elements
        if candidates.isEmpty {
            log("⚠️ No standard candidates found, expanding to all elements...")
            candidates = try bodyElement.select("*")
        }
        
        // If still no candidates, use direct children
        if candidates.isEmpty {
            log("⚠️ No elements found, using body children...")
            candidates = bodyElement.children()
        }
        
        var bestCandidate: Element?
        var bestScore = 0.0
        
        log("🔍 Evaluating \(candidates.count) content candidates...")
        
        // Debug: Show all candidates with any text content
        var candidatesWithText = 0
        var largeCandidates = 0
        for candidate in candidates {
            let textLength = try candidate.text().count
            if textLength > 0 {
                candidatesWithText += 1
                if textLength > 1000 {
                    largeCandidates += 1
                    let candidateClass = try candidate.attr("class").lowercased()
                    let candidateId = try candidate.attr("id").lowercased()
                    let tagName = candidate.tagName().lowercased()
                    log("🔍 LARGE candidate \(largeCandidates): \(tagName) class='\(candidateClass)' id='\(candidateId)' - \(textLength) chars")
                }
                if candidatesWithText <= 5 { // Show first 5 candidates with text
                    let candidateClass = try candidate.attr("class").lowercased()
                    let candidateId = try candidate.attr("id").lowercased()
                    let tagName = candidate.tagName().lowercased()
                    log("🔍 Debug candidate \(candidatesWithText): \(tagName) class='\(candidateClass)' id='\(candidateId)' - \(textLength) chars")
                }
            }
        }
        log("🔍 Found \(candidatesWithText) candidates with text content, \(largeCandidates) with >1000 chars")
        
        for candidate in candidates {
            // Get attributes for filtering
            let candidateClass = try candidate.attr("class").lowercased()
            let candidateId = try candidate.attr("id").lowercased()
            let tagName = candidate.tagName().lowercased()
            
            // Skip navigation, sidebars, ads, and other non-content elements
            let skipPatterns = ["nav", "sidebar", "menu", "header", "footer", "ad", "widget", 
                               "social", "share", "comment", "related", "popup", "modal", 
                               "banner", "promo", "newsletter"]
            
            let shouldSkip = skipPatterns.contains { pattern in
                candidateClass.contains(pattern) || candidateId.contains(pattern)
            }
            
            if shouldSkip {
                log("⏭️ Skipping non-content element: \(tagName) class='\(candidateClass)' id='\(candidateId)'")
                continue
            }
            
            // Skip very large containers that are likely page wrappers
            if candidateClass.contains("root") || candidateId.contains("root") ||
               candidateClass.contains("app") || candidateId.contains("app") ||
               candidateClass.contains("page") || candidateId.contains("page") ||
               candidateClass.contains("container") || candidateId.contains("container") {
                
                // But allow if they contain "content" 
                if !candidateClass.contains("content") && !candidateId.contains("content") {
                    log("⏭️ Skipping large container: \(tagName) class='\(candidateClass)' id='\(candidateId)'")
                    continue
                }
            }
            
            let textLength = try candidate.text().count
            
            // Skip elements that are too short, but be more lenient
            if textLength < 20 {
                log("⏭️ Skipping due to short length: \(tagName) - \(textLength) chars")
                continue
            }
            
            // Skip extremely long elements (but allow up to 100k for long articles)
            if textLength > 100000 {
                log("⏭️ Skipping due to excessive length: \(tagName) - \(textLength) chars")
                continue
            }
            
            let score = try calculateTextDensity(for: candidate)
            
            // Only log candidates with substantial text or high scores to reduce noise
            if textLength > 100 || score > 1.0 {
                log("📊 Candidate: \(tagName) class='\(candidateClass)' id='\(candidateId)' - Score: \(String(format: "%.2f", score)), Text: \(textLength) chars")
            }
            
            if score > bestScore && textLength > 50 { // Minimum 50 characters for content
                bestScore = score
                bestCandidate = candidate
                log("🏆 New best candidate with score \(String(format: "%.2f", score)) and \(textLength) chars")
            }
        }
        
        if let best = bestCandidate {
            log("✅ Selected: \(best.tagName()) with score \(String(format: "%.2f", bestScore))")
            return best
        } else {
            log("❌ No good candidate found, using body element")
            
            // Debug: Log body content to understand what we have
            let bodyText = try bodyElement.text()
            log("🔍 DEBUG: Body element text length: \(bodyText.count)")
            log("🔍 DEBUG: Body element children count: \(bodyElement.children().count)")
            log("🔍 DEBUG: First 500 chars of body text: '\(String(bodyText.prefix(500)))'")
            
            // Try to find any div with substantial content as fallback
            let fallbackCandidates = try bodyElement.select("div")
            log("🔍 DEBUG: Found \(fallbackCandidates.count) div elements")
            
            for (index, candidate) in fallbackCandidates.enumerated() {
                let textLength = try candidate.text().count
                log("🔍 DEBUG: Div \(index): \(textLength) characters")
                if index < 3 && textLength > 0 { // Log first 3 non-empty divs
                    let candidateText = try candidate.text()
                    log("🔍 DEBUG: Div \(index) text: '\(String(candidateText.prefix(200)))'")
                }
                
                if textLength > 100 { // Reduced from 500 to 100
                    log("🆘 Using fallback div with \(textLength) characters")
                    return candidate
                }
            }
            return bodyElement
        }
    }
    
    private func calculateTextDensity(for element: Element) throws -> Double {
        let text = try element.text()
        let textLength = Double(text.count)
        
        // Count child elements (tags)
        let childElements = try element.select("*").count
        let childElementCount = Double(max(childElements, 1))
        
        // Calculate text density (text length / number of tags)
        let density = textLength / childElementCount
        
        // Bonus for longer text
        let lengthBonus = min(textLength / 1000.0, 1.0)
        
        // Penalty for too many links (likely navigation)
        let links = try element.select("a").count
        let linkPenalty = Double(links) / max(textLength / 100.0, 1.0)
        
        return density + lengthBonus - linkPenalty
    }
    
    // MARK: - Markdown Conversion
    
    private func convertToMarkdown(_ element: Element, baseURL: URL? = nil) throws -> String {
        var markdown = ""
        
        // Process child nodes
        for child in element.children() {
            let childMarkdown = try processElement(child, baseURL: baseURL, depth: 0)
            if !childMarkdown.isEmpty {
                let trimmed = childMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    markdown += trimmed + "\n\n"
                }
            }
        }
        
        // Clean up excessive whitespace and empty lines
        let cleanedMarkdown = markdown
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleanedMarkdown
    }
    
    private func processElement(_ element: Element, baseURL: URL? = nil, depth: Int = 0) throws -> String {
        // Prevent infinite recursion
        guard depth < 50 else {
            log("⚠️ Max recursion depth reached for element: \(element.tagName())")
            return ""
        }
        let tagName = element.tagName().lowercased()
        let text = element.ownText()
        
        switch tagName {
        case "h1":
            let content = try processInlineElements(element, baseURL: baseURL, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : "# " + content
        case "h2":
            let content = try processInlineElements(element, baseURL: baseURL, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : "## " + content
        case "h3":
            let content = try processInlineElements(element, baseURL: baseURL, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : "### " + content
        case "h4":
            let content = try processInlineElements(element, baseURL: baseURL, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : "#### " + content
        case "h5":
            let content = try processInlineElements(element, baseURL: baseURL, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : "##### " + content
        case "h6":
            let content = try processInlineElements(element, baseURL: baseURL, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : "###### " + content
        case "p":
            return try processInlineElements(element, baseURL: baseURL, depth: depth + 1)
        case "strong", "b":
            return "**" + text + "**"
        case "em", "i":
            return "*" + text + "*"
        case "a":
            let href = try element.attr("href")
            let linkText = try element.text()
            // Only allow safe URLs for security
            let lowercasedHref = href.lowercased()
            if !lowercasedHref.hasPrefix("javascript:") && 
               (href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("/")) {
                return "[\(linkText)](\(href))"
            } else {
                // For unsafe URLs, just include the text
                return linkText
            }
        case "img":
            // Preserve image as markdown with resolved absolute URL
            let src = (try? element.attr("src")) ?? ""
            let alt = (try? element.attr("alt")) ?? ""
            
            // Only include images with valid src attributes
            if !src.isEmpty {
                // Resolve relative URLs to absolute URLs
                if let resolvedURL = resolveURL(src, baseURL: baseURL) {
                    return "![\(alt)](\(resolvedURL.absoluteString))"
                }
                // If resolveURL returns nil, the URL is invalid/unsafe - skip the image
            }
            return ""
        case "ul", "ol":
            return try processList(element, ordered: tagName == "ol", baseURL: baseURL, depth: depth + 1)
        case "li":
            return try processInlineElements(element, baseURL: baseURL, depth: depth + 1)
        case "blockquote":
            let content = try processInlineElements(element, baseURL: baseURL, depth: depth + 1)
            return "> " + content.replacingOccurrences(of: "\n", with: "\n> ")
        case "code":
            return "`" + text + "`"
        case "pre":
            let codeContent = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            return codeContent.isEmpty ? "" : "```\n" + codeContent + "\n```"
        case "br":
            return "\n"
        case "hr":
            return "\n---\n"
        case "div", "section", "article", "header", "footer", "main":
            // Process container elements recursively with proper spacing
            if element.children().count > 0 {
                var result = ""
                for child in element.children() {
                    let childMarkdown = try processElement(child, baseURL: baseURL, depth: depth + 1)
                    if !childMarkdown.isEmpty {
                        let trimmed = childMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            result += trimmed + "\n\n"
                        }
                    }
                }
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default:
            // For other elements, process children or return text
            if element.children().count > 0 {
                var result = ""
                for child in element.children() {
                    let childMarkdown = try processElement(child, baseURL: baseURL, depth: depth + 1)
                    if !childMarkdown.isEmpty {
                        result += childMarkdown + " "
                    }
                }
                return result.trimmingCharacters(in: .whitespaces)
            } else {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    
    private func processInlineElements(_ element: Element, baseURL: URL? = nil, depth: Int = 0) throws -> String {
        var result = ""
        
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                result += textNode.text()
            } else if let childElement = node as? Element {
                result += try processElement(childElement, baseURL: baseURL, depth: depth + 1)
            }
        }
        
        return result.trimmingCharacters(in: .whitespaces)
    }
    
    private func processList(_ element: Element, ordered: Bool, baseURL: URL? = nil, depth: Int = 0) throws -> String {
        var result = ""
        let items = try element.select("li")
        
        for (index, item) in items.enumerated() {
            let prefix = ordered ? "\(index + 1). " : "- "
            let itemText = try processInlineElements(item, baseURL: baseURL, depth: depth + 1)
            result += prefix + itemText + "\n"
        }
        
        return result
    }
    
    // MARK: - Image Extraction
    
    private func extractImages(from element: Element, baseURL: URL?) throws -> [String] {
        let images = try element.select("img[src]")
        var imageURLs: [String] = []
        
        for img in images {
            let src = try img.attr("src")
            if let resolvedURL = resolveURL(src, baseURL: baseURL) {
                imageURLs.append(resolvedURL.absoluteString)
            }
        }
        
        return imageURLs
    }
    
    private func resolveURL(_ urlString: String, baseURL: URL?) -> URL? {
        // Skip empty strings
        guard !urlString.isEmpty else { return nil }
        
        // Skip data URLs and javascript URLs
        let lowercased = urlString.lowercased()
        guard !lowercased.hasPrefix("data:") && !lowercased.hasPrefix("javascript:") else {
            return nil
        }
        
        // First try to create as absolute URL
        if let url = URL(string: urlString), url.scheme != nil {
            // Validate that it's a reasonable URL scheme
            guard url.scheme == "http" || url.scheme == "https" else {
                return nil
            }
            return url
        }
        
        // Handle relative URLs
        guard let baseURL = baseURL else {
            return nil
        }
        
        // Create URL relative to base and resolve it to absolute
        if let relativeURL = URL(string: urlString, relativeTo: baseURL) {
            let absoluteURL = relativeURL.absoluteURL
            // Validate the resolved URL has a proper scheme
            guard absoluteURL.scheme == "http" || absoluteURL.scheme == "https" else {
                return nil
            }
            return absoluteURL
        }
        
        return nil
    }
}

// MARK: - Data Models

public struct ExtractedContent: Sendable {
    public let title: String
    public let markdown: String
    public let images: [String]
    public let rawHTML: String
    
    public init(title: String, markdown: String, images: [String], rawHTML: String) {
        self.title = title
        self.markdown = markdown
        self.images = images
        self.rawHTML = rawHTML
    }
}
