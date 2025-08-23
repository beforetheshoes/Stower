import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public final class PDFExtractionService: Sendable {
    public let debugLogger: (@Sendable (String) -> Void)?
    
    public init(debugLogger: (@Sendable (String) -> Void)? = nil) {
        self.debugLogger = debugLogger
    }
    
    private func log(_ message: String) {
        print(message)
        debugLogger?(message)
    }
    
    public func extractContent(from pdfURL: URL) async throws -> ExtractedContent {
        return try await Task.detached {
            self.log("📄 PDFExtractionService: Starting PDF extraction for: \(pdfURL.lastPathComponent)")
            
            guard let pdfDocument = PDFDocument(url: pdfURL) else {
                throw PDFExtractionError.invalidPDF
            }
            
            let pageCount = pdfDocument.pageCount
            self.log("📊 PDF has \(pageCount) pages")
            
            guard pageCount > 0 else {
                throw PDFExtractionError.emptyPDF
            }
            
            // Extract title
            let title = self.extractTitle(from: pdfDocument, fallbackURL: pdfURL)
            self.log("📝 Extracted title: '\(title)'")
            
            // Process all pages
            var markdown = ""
            var totalTextLength = 0
            
            for pageIndex in 0..<pageCount {
                guard let page = pdfDocument.page(at: pageIndex) else {
                    self.log("⚠️ Could not access page \(pageIndex)")
                    continue
                }
                
                let pageMarkdown = try self.extractMarkdownFromPage(page, pageNumber: pageIndex + 1)
                if !pageMarkdown.isEmpty {
                    markdown += pageMarkdown + "\n\n"
                    totalTextLength += pageMarkdown.count
                }
            }
            
            self.log("✅ PDF extraction completed: \(totalTextLength) characters from \(pageCount) pages")
            
            // Clean up the final markdown
            let cleanedMarkdown = self.cleanupMarkdown(markdown)
            
            // Extract any images (optional - PDFs can have embedded images)
            let images = self.extractImageReferences(from: pdfDocument)
            
            return ExtractedContent(
                title: title,
                markdown: cleanedMarkdown,
                images: images,
                rawHTML: "" // PDFs don't have HTML
            )
        }.value
    }
    
    public func extractContent(from pdfData: Data) async throws -> ExtractedContent {
        return try await Task.detached {
            self.log("📄 PDFExtractionService: Starting PDF extraction from data (\(pdfData.count) bytes)")
            
            guard let pdfDocument = PDFDocument(data: pdfData) else {
                throw PDFExtractionError.invalidPDF
            }
            
            let pageCount = pdfDocument.pageCount
            self.log("📊 PDF has \(pageCount) pages")
            
            guard pageCount > 0 else {
                throw PDFExtractionError.emptyPDF
            }
            
            // Extract title (no URL fallback for data)
            let title = self.extractTitle(from: pdfDocument, fallbackURL: nil)
            self.log("📝 Extracted title: '\(title)'")
            
            // Process all pages
            var markdown = ""
            var totalTextLength = 0
            
            for pageIndex in 0..<pageCount {
                guard let page = pdfDocument.page(at: pageIndex) else {
                    self.log("⚠️ Could not access page \(pageIndex)")
                    continue
                }
                
                let pageMarkdown = try self.extractMarkdownFromPage(page, pageNumber: pageIndex + 1)
                if !pageMarkdown.isEmpty {
                    markdown += pageMarkdown + "\n\n"
                    totalTextLength += pageMarkdown.count
                }
            }
            
            self.log("✅ PDF extraction completed: \(totalTextLength) characters from \(pageCount) pages")
            
            // Clean up the final markdown
            let cleanedMarkdown = self.cleanupMarkdown(markdown)
            
            // Extract any images
            let images = self.extractImageReferences(from: pdfDocument)
            
            return ExtractedContent(
                title: title,
                markdown: cleanedMarkdown,
                images: images,
                rawHTML: ""
            )
        }.value
    }
    
    // MARK: - Title Extraction
    
    private func extractTitle(from document: PDFDocument, fallbackURL: URL?) -> String {
        // Try document metadata first
        if let documentAttributes = document.documentAttributes {
            if let title = documentAttributes[PDFDocumentAttribute.titleAttribute] as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Try to find title from first page content
        if let firstPage = document.page(at: 0) {
            if let attributedString = firstPage.attributedString {
                // Look for the largest text at the beginning as potential title
                let firstFewHundredChars = attributedString.length > 500 ? 
                    attributedString.attributedSubstring(from: NSRange(location: 0, length: 500)) : 
                    attributedString
                
                var largestFont: CGFloat = 0
                var titleCandidate = ""
                
                firstFewHundredChars.enumerateAttributes(in: NSRange(location: 0, length: firstFewHundredChars.length)) { attrs, range, _ in
                    let substring = firstFewHundredChars.attributedSubstring(from: range).string
                    let cleanText = substring.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    var fontSize: CGFloat = 12.0
                    
                    #if canImport(AppKit)
                    if let font = attrs[.font] as? NSFont {
                        fontSize = font.pointSize
                    }
                    #elseif canImport(UIKit)
                    if let font = attrs[.font] as? UIFont {
                        fontSize = font.pointSize
                    }
                    #endif
                    
                    if fontSize > largestFont && cleanText.count > 5 && cleanText.count < 200 {
                        // Potential title: large font, reasonable length
                        largestFont = fontSize
                        titleCandidate = cleanText
                    }
                }
                
                if !titleCandidate.isEmpty {
                    return titleCandidate
                }
            }
        }
        
        // Fallback to filename or generic title
        if let url = fallbackURL {
            let filename = url.deletingPathExtension().lastPathComponent
            return filename.isEmpty ? "PDF Document" : filename
        }
        
        return "PDF Document"
    }
    
    // MARK: - Page Processing
    
    private func extractMarkdownFromPage(_ page: PDFPage, pageNumber: Int) throws -> String {
        log("📄 Processing page \(pageNumber)...")
        
        // Try attributed string first (better formatting info)
        if let attributedString = page.attributedString {
            let markdown = try processAttributedString(attributedString)
            if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log("✅ Page \(pageNumber): extracted \(markdown.count) characters using attributed string")
                return markdown
            }
        }
        
        // Fallback to plain string
        if let plainString = page.string {
            let cleaned = plainString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                log("✅ Page \(pageNumber): extracted \(cleaned.count) characters using plain string")
                return cleaned
            }
        }
        
        log("⚠️ Page \(pageNumber): no text content found")
        return ""
    }
    
    private func processAttributedString(_ attributedString: NSAttributedString) throws -> String {
        // First, analyze the document structure to understand formatting patterns
        let structuralInfo = analyzeDocumentStructure(attributedString)
        
        // Parse the text into structured elements
        let elements = parseTextElements(attributedString, using: structuralInfo)
        
        // Convert elements to markdown
        return convertElementsToMarkdown(elements)
    }
    
    private func analyzeDocumentStructure(_ attributedString: NSAttributedString) -> DocumentStructuralInfo {
        var commonFontSize: CGFloat = 12.0
        var maxFontSize: CGFloat = 12.0
        var fontSizeFrequency: [CGFloat: Int] = [:]
        
        let fullRange = NSRange(location: 0, length: attributedString.length)
        
        // Analyze font patterns across the document
        attributedString.enumerateAttributes(in: fullRange) { attrs, range, _ in
            var fontSize: CGFloat = 12.0
            
            #if canImport(AppKit)
            if let font = attrs[.font] as? NSFont {
                fontSize = font.pointSize
            }
            #elseif canImport(UIKit)
            if let font = attrs[.font] as? UIFont {
                fontSize = font.pointSize
            }
            #endif
            
            // Round font sizes to reduce granularity (group similar sizes)
            let roundedFontSize = round(fontSize * 2.0) / 2.0  // Round to nearest 0.5pt
            
            maxFontSize = max(maxFontSize, roundedFontSize)
            fontSizeFrequency[roundedFontSize, default: 0] += range.length
        }
        
        // Find the most common font size (likely body text)
        if let mostCommon = fontSizeFrequency.max(by: { $0.value < $1.value }) {
            commonFontSize = mostCommon.key
        }
        
        return DocumentStructuralInfo(
            commonFontSize: commonFontSize,
            maxFontSize: maxFontSize,
            fontSizeFrequency: fontSizeFrequency
        )
    }
    
    private func parseTextElements(_ attributedString: NSAttributedString, using structuralInfo: DocumentStructuralInfo) -> [TextElement] {
        var elements: [TextElement] = []
        let fullRange = NSRange(location: 0, length: attributedString.length)
        
        var currentElement: TextElement?
        var currentText = ""
        var lastFont: Any?
        var lastFontSize: CGFloat = 12.0
        
        attributedString.enumerateAttributes(in: fullRange) { attrs, range, _ in
            let substring = attributedString.attributedSubstring(from: range).string
            
            var fontSize: CGFloat = 12.0
            var isBold = false
            var isItalic = false
            var currentFont: Any?
            
            #if canImport(AppKit)
            if let font = attrs[.font] as? NSFont {
                fontSize = font.pointSize
                isBold = font.fontDescriptor.symbolicTraits.contains(.bold)
                isItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
                currentFont = font
            }
            #elseif canImport(UIKit)
            if let font = attrs[.font] as? UIFont {
                fontSize = font.pointSize
                isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
                isItalic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
                currentFont = font
            }
            #endif
            
            // Check if we need to start a new element
            let shouldStartNewElement = lastFont == nil || 
                                      abs(fontSize - lastFontSize) > 0.5 ||  // Reduced threshold for font size changes
                                      substring.contains("\n\n") ||
                                      substring.contains("\r\n\r\n") ||
                                      hasSignificantLineBreak(substring, currentText: currentText)
            
            if shouldStartNewElement && !currentText.isEmpty {
                // Complete current element
                if let element = currentElement {
                    elements.append(TextElement(
                        text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                        fontSize: element.fontSize,
                        isBold: element.isBold,
                        isItalic: element.isItalic,
                        type: determineElementType(
                            text: currentText,
                            fontSize: element.fontSize,
                            isBold: element.isBold,
                            structuralInfo: structuralInfo
                        )
                    ))
                }
                currentText = ""
            }
            
            // Update current element info
            currentElement = TextElement(
                text: "",
                fontSize: fontSize,
                isBold: isBold,
                isItalic: isItalic,
                type: .paragraph
            )
            
            // Add text to current element
            currentText += substring
            lastFont = currentFont
            lastFontSize = fontSize
        }
        
        // Add final element
        if !currentText.isEmpty, let element = currentElement {
            elements.append(TextElement(
                text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                fontSize: element.fontSize,
                isBold: element.isBold,
                isItalic: element.isItalic,
                type: determineElementType(
                    text: currentText,
                    fontSize: element.fontSize,
                    isBold: element.isBold,
                    structuralInfo: structuralInfo
                )
            ))
        }
        
        return elements
    }
    
    private func determineElementType(text: String, fontSize: CGFloat, isBold: Bool, structuralInfo: DocumentStructuralInfo) -> TextElementType {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if it's a list item
        if isListItem(trimmedText) {
            return .listItem
        }
        
        // Round the fontSize for comparison (same rounding as in analysis)
        let roundedFontSize = round(fontSize * 2.0) / 2.0
        let fontSizeRatio = roundedFontSize / structuralInfo.commonFontSize
        
        // More conservative heading detection with better academic paper logic
        let isLikelyHeading = isLikelyHeading(text: trimmedText, fontSize: roundedFontSize, fontSizeRatio: fontSizeRatio, isBold: isBold)
        
        if isLikelyHeading {
            // Use font size ratio to determine heading level
            if fontSizeRatio >= 1.6 {
                return .heading1
            } else if fontSizeRatio >= 1.3 {
                return .heading2
            } else {
                return .heading3
            }
        }
        
        return .paragraph
    }
    
    private func isLikelyHeading(text: String, fontSize: CGFloat, fontSizeRatio: CGFloat, isBold: Bool) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Exclude obvious non-headings
        if isLikelyNonHeading(trimmedText) {
            return false
        }
        
        // Strong indicators of headings
        if fontSizeRatio >= 1.5 {  // Significantly larger font
            return true
        }
        
        // Medium font size with additional indicators
        if fontSizeRatio >= 1.2 {
            // Check for heading-like content patterns
            if isBold || 
               trimmedText.count < 80 ||  // Short text
               isHeadingPattern(trimmedText) {
                return true
            }
        }
        
        // Small font size differences but strong other indicators
        if fontSizeRatio >= 1.1 {
            if isBold && trimmedText.count < 50 && isHeadingPattern(trimmedText) {
                return true
            }
        }
        
        return false
    }
    
    private func isLikelyNonHeading(_ text: String) -> Bool {
        // Exclude patterns that are clearly not headings
        
        // Single numbers or very short isolated text (like author affiliations)
        if text.count <= 3 && (text.allSatisfy { $0.isNumber } || text.allSatisfy { $0.isWhitespace || $0.isNumber }) {
            return true
        }
        
        // Author names with numbers (institutional affiliations)
        if text.count < 30 && text.range(of: #"\d+"#, options: .regularExpression) != nil {
            // Looks like "John Smith1,2" or "Peter Belcak1"
            if text.range(of: #"[A-Z][a-z]+\s+[A-Z][a-z]+\d*"#, options: .regularExpression) != nil {
                return true
            }
        }
        
        // Single words that are likely names (short, capitalized, no special chars)
        if text.count < 20 && text.count > 2 {
            let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if words.count <= 2 && words.allSatisfy({ word in
                word.first?.isUppercase == true && word.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber })
            }) {
                return true
            }
        }
        
        // Email addresses
        if text.contains("@") && text.contains(".") {
            return true
        }
        
        // URLs
        if text.hasPrefix("http") || text.contains("://") {
            return true
        }
        
        // Very long text is usually paragraph content
        if text.count > 200 {
            return true
        }
        
        // Text that looks like regular paragraph content
        if text.contains(".") && text.count > 100 {
            return true
        }
        
        return false
    }
    
    private func isHeadingPattern(_ text: String) -> Bool {
        // Patterns that suggest this is a heading
        
        // Starts with a number (section numbering)
        if text.range(of: #"^\d+\.?\s"#, options: .regularExpression) != nil {
            return true
        }
        
        // Common academic paper section headers
        let commonHeaders = [
            "abstract", "introduction", "background", "methodology", "methods",
            "results", "discussion", "conclusion", "references", "acknowledgments",
            "appendix", "related work", "evaluation", "experiments", "analysis"
        ]
        
        let lowerText = text.lowercased()
        for header in commonHeaders {
            if lowerText.contains(header) && text.count < 50 {
                return true
            }
        }
        
        // All caps text (often headings)
        if text.count > 5 && text.count < 50 && text.uppercased() == text {
            return true
        }
        
        // Text ending with colon (often section headers)
        if text.hasSuffix(":") && text.count < 80 {
            return true
        }
        
        return false
    }
    
    private func hasSignificantLineBreak(_ substring: String, currentText: String) -> Bool {
        // Detect meaningful paragraph breaks
        if substring.contains("\n") {
            // Check if this looks like the end of a sentence or paragraph
            let trimmedCurrent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCurrent.hasSuffix(".") || trimmedCurrent.hasSuffix("!") || trimmedCurrent.hasSuffix("?") {
                return true
            }
            
            // Check if the new line starts with a capital letter or number (new sentence/section)
            let afterNewline = substring.components(separatedBy: .newlines).dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !afterNewline.isEmpty && (afterNewline.first?.isUppercase == true || afterNewline.first?.isNumber == true) {
                return true
            }
        }
        
        return false
    }
    
    private func convertElementsToMarkdown(_ elements: [TextElement]) -> String {
        var markdown = ""
        var lastElementType: TextElementType?
        
        for element in elements {
            let elementMarkdown = formatElement(element)
            
            if !elementMarkdown.isEmpty {
                // Add appropriate spacing based on element types
                let spacing = determineSpacing(
                    previousType: lastElementType,
                    currentType: element.type
                )
                
                markdown += spacing + elementMarkdown
                lastElementType = element.type
            }
        }
        
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func formatElement(_ element: TextElement) -> String {
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        
        switch element.type {
        case .heading1:
            return "# \(text)"
        case .heading2:
            return "## \(text)"
        case .heading3:
            return "### \(text)"
        case .listItem:
            return formatListItem(text)
        case .paragraph:
            return formatParagraphText(text, isBold: element.isBold, isItalic: element.isItalic)
        }
    }
    
    private func formatParagraphText(_ text: String, isBold: Bool, isItalic: Bool) -> String {
        var formattedText = text
        
        // Apply bold/italic formatting
        if isBold && isItalic {
            formattedText = "***\(formattedText)***"
        } else if isBold {
            formattedText = "**\(formattedText)**"
        } else if isItalic {
            formattedText = "*\(formattedText)*"
        }
        
        return formattedText
    }
    
    private func determineSpacing(previousType: TextElementType?, currentType: TextElementType) -> String {
        guard let previousType = previousType else { return "" }
        
        switch (previousType, currentType) {
        case (.heading1, _), (.heading2, _), (.heading3, _):
            return "\n\n"
        case (_, .heading1), (_, .heading2), (_, .heading3):
            return "\n\n"
        case (.listItem, .listItem):
            return "\n"
        case (.listItem, _), (_, .listItem):
            return "\n\n"
        case (.paragraph, .paragraph):
            return "\n\n"
        default:
            return "\n\n"
        }
    }
    
    private func applyMarkdownFormatting(text: String, fontSize: CGFloat, isBold: Bool, isItalic: Bool) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }
        
        // Header detection based on font size
        if fontSize > 22 {
            return "# " + trimmedText
        } else if fontSize > 18 {
            return "## " + trimmedText
        } else if fontSize > 16 {
            return "### " + trimmedText
        }
        
        // List detection
        if isListItem(trimmedText) {
            return formatListItem(trimmedText)
        }
        
        // Bold/italic formatting for regular text
        var formattedText = trimmedText
        if isBold && isItalic {
            formattedText = "***" + formattedText + "***"
        } else if isBold {
            formattedText = "**" + formattedText + "**"
        } else if isItalic {
            formattedText = "*" + formattedText + "*"
        }
        
        return formattedText
    }
    
    internal func isListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for bullet point indicators
        let bulletPatterns = [
            #"^[•◦▪▫‣▸▹▶‣→⇒➤➢⟨⟩★☆▹⊚⊛⊙] "#,  // Various bullet symbols
            #"^[-–—*+] "#,                           // Simple bullets
            #"^\d+[\.\)] "#,                         // Numbered lists (1. or 1))
            #"^[a-zA-Z][\.\)] "#,                    // Letter lists (a. or A))
            #"^[ivxlcdm]+[\.\)] "#,                 // Roman numerals
            #"^\([a-zA-Z0-9]+\) "#,                  // Parenthetical numbering (1) or (a))
            #"^○ |^● |^◦ |^◉ "#,                     // Circle bullets
        ]
        
        for pattern in bulletPatterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        // Check for indented text that might be a sub-item
        if trimmed.hasPrefix("    ") || trimmed.hasPrefix("\t") {
            let indentRemoved = trimmed.replacingOccurrences(of: #"^[\s\t]+"#, with: "", options: .regularExpression)
            return isListItem(indentRemoved)
        }
        
        return false
    }
    
    private func formatListItem(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Detect and preserve indentation level
        let indentLevel = detectIndentationLevel(trimmed)
        let indent = String(repeating: "  ", count: indentLevel)
        
        // Remove leading indentation for processing
        let deindented = trimmed.replacingOccurrences(of: #"^[\s\t]+"#, with: "", options: .regularExpression)
        
        // Convert various list formats to standard markdown
        var formattedContent = ""
        
        // Handle bullet points
        let bulletPatterns: [(pattern: String, replacement: String)] = [
            (#"^[•◦▪▫‣▸▹▶‣→⇒➤➢⟨⟩★☆▹⊚⊛⊙] "#, "- "),
            (#"^[-–—*+] "#, "- "),
            (#"^○ |^● |^◦ |^◉ "#, "- ")
        ]
        
        var wasConverted = false
        for (pattern, replacement) in bulletPatterns {
            if let range = deindented.range(of: pattern, options: .regularExpression) {
                let content = String(deindented[range.upperBound...])
                formattedContent = indent + replacement + content
                wasConverted = true
                break
            }
        }
        
        // Handle numbered/lettered lists
        if !wasConverted {
            let numberedPatterns: [(pattern: String, format: String)] = [
                (#"^(\d+)[\.\)] "#, "$1. "),                    // 1. or 1)
                (#"^([a-zA-Z])[\.\)] "#, "$1. "),              // a. or A.
                (#"^([ivxlcdm]+)[\.\)] "#, "$1. "),            // Roman numerals
                (#"^\(([a-zA-Z0-9]+)\) "#, "$1. ")             // (1) or (a)
            ]
            
            for (pattern, _) in numberedPatterns {
                if let range = deindented.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    let fullMatch = String(deindented[range])
                    let content = String(deindented[range.upperBound...])
                    
                    // Extract the number/letter part for formatting
                    if let numberMatch = fullMatch.range(of: #"[a-zA-Z0-9ivxlcdm]+"#, options: [.regularExpression, .caseInsensitive]) {
                        let number = String(fullMatch[numberMatch])
                        formattedContent = indent + "\(number). \(content)"
                        wasConverted = true
                        break
                    }
                }
            }
        }
        
        // If no pattern matched, treat as a simple bullet
        if !wasConverted {
            formattedContent = indent + "- \(deindented)"
        }
        
        return formattedContent
    }
    
    private func detectIndentationLevel(_ text: String) -> Int {
        let leadingWhitespace = text.prefix { $0.isWhitespace }
        
        // Count tabs as 4 spaces, regular spaces as 1
        var indentCount = 0
        for char in leadingWhitespace {
            if char == "\t" {
                indentCount += 4
            } else if char == " " {
                indentCount += 1
            }
        }
        
        // Convert to markdown indentation levels (every 2 spaces = 1 level)
        return max(0, indentCount / 2)
    }
    
    // MARK: - Link Extraction
    
    private func extractImageReferences(from document: PDFDocument) -> [String] {
        var imageRefs: [String] = []
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            // Check for annotations that might reference images
            for annotation in page.annotations {
                // PDFAnnotation doesn't have a simple type check, so we check for common image-related annotation types
                // This is a simplified approach - PDFs can have complex image references
                if annotation.type == "Widget" || annotation.type == "Stamp" {
                    imageRefs.append("page-\(pageIndex + 1)-image")
                }
            }
        }
        
        return imageRefs
    }
    
    // MARK: - Cleanup
    
    internal func cleanupMarkdown(_ markdown: String) -> String {
        var cleaned = markdown
        
        // Fix hyphenated line breaks (common in PDFs) - but preserve intentional hyphens
        cleaned = cleaned.replacingOccurrences(of: #"([a-z])-\s*\n\s*([a-z])"#, with: "$1$2", options: .regularExpression)
        
        // Fix broken words across lines
        cleaned = cleaned.replacingOccurrences(of: #"([a-zA-Z])\n\s*([a-z])"#, with: "$1$2", options: .regularExpression)
        
        // Clean up spacing around punctuation
        cleaned = cleaned.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        
        // Normalize whitespace within lines
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        
        // Fix spacing around markdown formatting
        cleaned = cleaned.replacingOccurrences(of: #"(\*+)\s+([^\*]+)\s+(\*+)"#, with: "$1$2$3", options: .regularExpression)
        
        // Clean up excessive line breaks but preserve intentional spacing
        cleaned = cleaned.replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\n{3}"#, with: "\n\n", options: .regularExpression)
        
        // Remove trailing whitespace from lines
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        
        // Fix list spacing
        cleaned = cleaned.replacingOccurrences(of: #"\n\n(-|\d+\.|\*) "#, with: "\n$1 ", options: .regularExpression)
        
        // Ensure proper spacing after headings
        cleaned = cleaned.replacingOccurrences(of: #"(#{1,6} [^\n]+)\n([^\n#])"#, with: "$1\n\n$2", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Supporting Data Structures

private struct DocumentStructuralInfo {
    let commonFontSize: CGFloat
    let maxFontSize: CGFloat
    let fontSizeFrequency: [CGFloat: Int]
}

private struct TextElement {
    let text: String
    let fontSize: CGFloat
    let isBold: Bool
    let isItalic: Bool
    let type: TextElementType
}

private enum TextElementType {
    case heading1
    case heading2
    case heading3
    case paragraph
    case listItem
}

// MARK: - Error Types

public enum PDFExtractionError: Error, LocalizedError {
    case invalidPDF
    case emptyPDF
    case processingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "The file is not a valid PDF or is corrupted."
        case .emptyPDF:
            return "The PDF contains no pages or content."
        case .processingError(let message):
            return "PDF processing failed: \(message)"
        }
    }
}