import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public final class PDFDiagnosticService {
    public static func analyzePDF(at url: URL) {
        print("🔍 PDF DIAGNOSTIC ANALYSIS")
        print("📄 File: \(url.lastPathComponent)")
        
        guard let pdfDocument = PDFDocument(url: url) else {
            print("❌ Could not open PDF")
            return
        }
        
        print("📊 Pages: \(pdfDocument.pageCount)")
        
        // Analyze document metadata
        if let attributes = pdfDocument.documentAttributes {
            print("\n📋 Document Metadata:")
            for (key, value) in attributes {
                print("  \(key): \(value)")
            }
        }
        
        // Analyze first few pages in detail
        let pagesToAnalyze = min(3, pdfDocument.pageCount)
        
        for pageIndex in 0..<pagesToAnalyze {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            print("\n📄 Page \(pageIndex + 1) Analysis:")
            
            // Plain text extraction
            if let plainText = page.string {
                print("  Plain text length: \(plainText.count) characters")
                let preview = String(plainText.prefix(200))
                print("  Text preview: \"\(preview)...\"")
            }
            
            // Attributed string analysis
            if let attributedString = page.attributedString {
                print("  Attributed string length: \(attributedString.length) characters")
                analyzeFontsInAttributedString(attributedString)
            } else {
                print("  ❌ No attributed string available")
            }
            
            // Annotations
            print("  Annotations: \(page.annotations.count)")
            for annotation in page.annotations {
                print("    - Type: \(annotation.type ?? "Unknown")")
            }
        }
    }
    
    private static func analyzeFontsInAttributedString(_ attributedString: NSAttributedString) {
        var fontInfo: [String: Int] = [:]
        var sizeInfo: [CGFloat: Int] = [:]
        var traitInfo: [String: Int] = [:]
        
        let fullRange = NSRange(location: 0, length: attributedString.length)
        
        attributedString.enumerateAttributes(in: fullRange) { attrs, range, _ in
            #if canImport(AppKit)
            if let font = attrs[.font] as? NSFont {
                let fontName = font.familyName ?? font.fontName
                let fontSize = font.pointSize
                fontInfo[fontName, default: 0] += range.length
                sizeInfo[fontSize, default: 0] += range.length
                
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    traitInfo["Bold", default: 0] += range.length
                }
                if traits.contains(.italic) {
                    traitInfo["Italic", default: 0] += range.length
                }
            }
            #elseif canImport(UIKit)
            if let font = attrs[.font] as? UIFont {
                let fontName = font.familyName
                let fontSize = font.pointSize
                fontInfo[fontName, default: 0] += range.length
                sizeInfo[fontSize, default: 0] += range.length
                
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) {
                    traitInfo["Bold", default: 0] += range.length
                }
                if traits.contains(.traitItalic) {
                    traitInfo["Italic", default: 0] += range.length
                }
            }
            #endif
        }
        
        print("  🔤 Font families found:")
        let sortedFonts = fontInfo.sorted { $0.value > $1.value }
        for (font, count) in sortedFonts.prefix(5) {
            print("    - \(font): \(count) characters")
        }
        
        print("  📏 Font sizes found:")
        let sortedSizes = sizeInfo.sorted { $0.value > $1.value }
        for (size, count) in sortedSizes.prefix(10) {
            print("    - \(size)pt: \(count) characters")
        }
        
        if !traitInfo.isEmpty {
            print("  🎨 Font traits:")
            for (trait, count) in traitInfo {
                print("    - \(trait): \(count) characters")
            }
        }
        
        // Find most common font size (body text)
        if let mostCommonSize = sortedSizes.first {
            print("  📖 Most common size (likely body): \(mostCommonSize.0)pt")
            
            // Find larger sizes that could be headings
            let headingSizes = sortedSizes.filter { (size, _) in
                size > mostCommonSize.0 * 1.1
            }
            
            if !headingSizes.isEmpty {
                print("  📰 Potential heading sizes:")
                for (size, count) in headingSizes {
                    let ratio = size / mostCommonSize.0
                    print("    - \(size)pt (×\(String(format: "%.2f", ratio))): \(count) chars")
                }
            }
        }
    }
}