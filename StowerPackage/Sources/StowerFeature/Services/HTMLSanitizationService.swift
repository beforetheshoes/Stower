import Foundation
import SwiftSoup

/// Service for safely converting HTML to Markdown with security safeguards
@MainActor
public class HTMLSanitizationService {
    
    public init() {}
    
    /// Safely converts HTML to Markdown, removing dangerous elements and preserving safe formatting
    public func sanitizeAndConvertToMarkdown(_ html: String) throws -> String {
        // Parse HTML with SwiftSoup
        let document = try SwiftSoup.parse(html)
        
        // Remove dangerous elements and attributes
        try sanitizeDocument(document)
        
        // Convert to Markdown
        let markdown = try convertToMarkdown(document)
        
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Removes dangerous HTML elements and attributes
    private func sanitizeDocument(_ document: Document) throws {
        // Remove all script tags and their content
        try document.select("script").remove()
        
        // Remove style tags (CSS can contain JavaScript)
        try document.select("style").remove()
        
        // Remove iframe, object, embed, applet tags
        try document.select("iframe, object, embed, applet").remove()
        
        // Remove form elements that could be problematic
        try document.select("form, input, button, select, textarea").remove()
        
        // Remove link tags (could reference external resources)
        try document.select("link").remove()
        
        // Remove meta tags with JavaScript
        try document.select("meta").remove()
        
        // Remove dangerous attributes from all elements
        let dangerousAttributes = [
            "onclick", "onload", "onerror", "onmouseover", "onmouseout",
            "onsubmit", "onchange", "onfocus", "onblur", "onkeydown",
            "onkeyup", "onkeypress", "ondblclick", "oncontextmenu",
            "ondrag", "ondrop", "onmousemove", "onmouseup", "onmousedown",
            "style", // Remove inline styles which could contain JavaScript
            "class", // Remove classes to prevent CSS injection
            "id"     // Remove IDs to prevent targeting
        ]
        
        // Select all elements and remove dangerous attributes
        let allElements = try document.select("*")
        for element in allElements.array() {
            for attr in dangerousAttributes {
                try element.removeAttr(attr)
            }
            
            // Also check for javascript: URLs in href and src attributes
            if let href = try? element.attr("href"), href.lowercased().hasPrefix("javascript:") {
                try element.removeAttr("href")
            }
            if let src = try? element.attr("src"), src.lowercased().hasPrefix("javascript:") {
                try element.removeAttr("src")
            }
        }
    }
    
    /// Converts sanitized HTML document to Markdown
    private func convertToMarkdown(_ document: Document) throws -> String {
        let body = document.body() ?? document
        return try convertElementToMarkdown(body, depth: 0)
    }
    
    /// Recursively converts HTML elements to Markdown
    private func convertElementToMarkdown(_ element: Element, depth: Int) throws -> String {
        var markdown = ""
        let tagName = element.tagName().lowercased()
        
        // Handle different HTML elements
        switch tagName {
        case "h1":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                markdown += "# \(text)\n\n"
            }
            
        case "h2":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                markdown += "## \(text)\n\n"
            }
            
        case "h3":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                markdown += "### \(text)\n\n"
            }
            
        case "h4":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                markdown += "#### \(text)\n\n"
            }
            
        case "h5":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                markdown += "##### \(text)\n\n"
            }
            
        case "h6":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                markdown += "###### \(text)\n\n"
            }
            
        case "p":
            let content = try convertChildrenToMarkdown(element, depth: depth + 1)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += "\(content)\n\n"
            }
            
        case "br":
            markdown += "\n"
            
        case "strong", "b":
            let content = try convertChildrenToMarkdown(element, depth: depth + 1)
            if !content.isEmpty {
                markdown += "**\(content)**"
            }
            
        case "em", "i":
            let content = try convertChildrenToMarkdown(element, depth: depth + 1)
            if !content.isEmpty {
                markdown += "*\(content)*"
            }
            
        case "code":
            let text = try element.text()
            if !text.isEmpty {
                markdown += "`\(text)`"
            }
            
        case "pre":
            let text = try element.text()
            if !text.isEmpty {
                markdown += "```\n\(text)\n```\n\n"
            }
            
        case "a":
            let text = try element.text()
            if let href = try? element.attr("href"), !href.isEmpty, !text.isEmpty {
                // Only allow http/https URLs for security
                if href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("/") {
                    markdown += "[\(text)](\(href))"
                } else {
                    // For unsafe URLs, just include the text
                    markdown += text
                }
            } else if !text.isEmpty {
                markdown += text
            }
            
        case "img":
            if let alt = try? element.attr("alt"), 
               let src = try? element.attr("src"), !src.isEmpty {
                // Only allow safe image URLs
                if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("/") || src.hasPrefix("data:image/") {
                    let altText = alt.isEmpty ? "Image" : alt
                    markdown += "![\(altText)](\(src))"
                }
            }
            
        case "ul":
            let content = try convertChildrenToMarkdown(element, depth: depth + 1)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += "\(content)\n"
            }
            
        case "ol":
            var itemNumber = 1
            for child in element.children().array() {
                if child.tagName().lowercased() == "li" {
                    let content = try convertChildrenToMarkdown(child, depth: depth + 1)
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        markdown += "\(itemNumber). \(content)\n"
                        itemNumber += 1
                    }
                }
            }
            if !markdown.isEmpty {
                markdown += "\n"
            }
            
        case "li":
            // Handle list items (this is called from ul processing)
            if element.parent()?.tagName().lowercased() == "ul" {
                let content = try convertChildrenToMarkdown(element, depth: depth + 1)
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    markdown += "- \(content)\n"
                }
            }
            // ol items are handled in the "ol" case above
            
        case "blockquote":
            let content = try convertChildrenToMarkdown(element, depth: depth + 1)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lines = content.components(separatedBy: .newlines)
                for line in lines {
                    if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        markdown += "> \(line)\n"
                    }
                }
                markdown += "\n"
            }
            
        case "hr":
            markdown += "---\n\n"
            
        case "table":
            // Basic table support
            let content = try convertChildrenToMarkdown(element, depth: depth + 1)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += "\(content)\n"
            }
            
        case "tr":
            let cells = element.children().array()
            var row = "|"
            for cell in cells {
                let cellContent = try convertChildrenToMarkdown(cell, depth: depth + 1)
                row += " \(cellContent.replacingOccurrences(of: "\n", with: " ")) |"
            }
            markdown += "\(row)\n"
            
            // Add header separator for first row if this is in a thead or first tr
            if let parent = element.parent(), 
               (parent.tagName().lowercased() == "thead" || 
                element.siblingIndex == 0) {
                var separator = "|"
                for _ in cells {
                    separator += " --- |"
                }
                markdown += "\(separator)\n"
            }
            
        case "th", "td":
            // Cell content is handled by tr processing
            break
            
        default:
            // For unknown or unhandled tags, just process children
            let content = try convertChildrenToMarkdown(element, depth: depth + 1)
            markdown += content
        }
        
        return markdown
    }
    
    /// Converts child elements to Markdown
    private func convertChildrenToMarkdown(_ element: Element, depth: Int) throws -> String {
        var markdown = ""
        
        // Use getChildNodes() instead of childNodes()
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                markdown += textNode.text()
            } else if let childElement = node as? Element {
                markdown += try convertElementToMarkdown(childElement, depth: depth)
            }
        }
        
        return markdown
    }
}