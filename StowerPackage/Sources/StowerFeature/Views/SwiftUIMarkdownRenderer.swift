import SwiftUI
import Markdown

/// A SwiftUI renderer that uses swift-markdown's Document parsing
public struct SwiftUIMarkdownRenderer: View {
    let markdownText: String
    let readerSettings: ReaderSettings
    
    public init(markdownText: String, readerSettings: ReaderSettings) {
        self.markdownText = markdownText
        self.readerSettings = readerSettings
    }
    
    public var body: some View {
        let document = Document(parsing: markdownText)
        
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(document.children.enumerated()), id: \.offset) { index, child in
                    MarkdownElementView(markup: child, readerSettings: readerSettings)
                        .id("markup_\(index)")
                }
            }
            .padding()
        }
    }
}

// MARK: - Simple Element View

struct MarkdownElementView: View {
    let markup: Markup
    let readerSettings: ReaderSettings
    
    var body: some View {
        Group {
            switch markup {
            case let paragraph as Paragraph:
                Text(renderInlineMarkup(paragraph))
                    .font(.system(size: readerSettings.effectiveFontSize, design: readerSettings.effectiveFont.fontDesign))
                    .foregroundColor(readerSettings.effectiveTextColor)
                    .lineSpacing(readerSettings.effectiveFontSize * 0.25)
                
            case let heading as Heading:
                let fontSize = headingFontSize(for: heading.level)
                Text(renderInlineMarkup(heading))
                    .font(.system(size: fontSize, weight: .bold, design: readerSettings.effectiveFont.fontDesign))
                    .foregroundColor(readerSettings.effectiveAccentColor)
                    .padding(.top, headingTopPadding(for: heading.level))
                    .padding(.bottom, headingBottomPadding(for: heading.level))
                
            case let codeBlock as CodeBlock:
                ScrollView(.horizontal) {
                    Text(codeBlock.code)
                        .font(.system(size: readerSettings.effectiveFontSize * 0.9, design: .monospaced))
                        .foregroundColor(readerSettings.effectiveAccentColor)
                        .padding()
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(readerSettings.effectiveAccentColor.opacity(0.2), lineWidth: 1)
                )
                .padding(.vertical, readerSettings.effectiveFontSize * 0.5)
                
            case let unorderedList as UnorderedList:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(unorderedList.children.enumerated()), id: \.offset) { _, child in
                        if let listItem = child as? ListItem {
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .font(.system(size: readerSettings.effectiveFontSize, design: readerSettings.effectiveFont.fontDesign))
                                    .foregroundColor(readerSettings.effectiveAccentColor)
                                
                                Text(renderInlineMarkup(listItem))
                                    .font(.system(size: readerSettings.effectiveFontSize, design: readerSettings.effectiveFont.fontDesign))
                                    .foregroundColor(readerSettings.effectiveTextColor)
                            }
                            .padding(.leading, 16)
                        }
                    }
                }
                .padding(.vertical, readerSettings.effectiveFontSize * 0.3)
                
            default:
                EmptyView()
            }
        }
    }
    
    // Helper methods for MarkdownElementView
    private func renderInlineMarkup(_ markup: Markup) -> AttributedString {
        // Simple text extraction without recursion
        var result = AttributedString()
        for child in markup.children {
            if let text = child as? Markdown.Text {
                result += AttributedString(text.string)
            } else {
                // Extract just the text content recursively but safely
                result += AttributedString(extractPlainText(from: child))
            }
        }
        return result
    }
    
    private func extractPlainText(from markup: Markup) -> String {
        var text = ""
        for child in markup.children {
            if let textNode = child as? Markdown.Text {
                text += textNode.string
            } else {
                text += extractPlainText(from: child)
            }
        }
        return text
    }
    
    
    private func headingFontSize(for level: Int) -> CGFloat {
        let multipliers: [CGFloat] = [2.2, 1.8, 1.5, 1.3, 1.1, 1.05]
        let index = min(level - 1, multipliers.count - 1)
        return readerSettings.effectiveFontSize * multipliers[index]
    }
    
    private func headingTopPadding(for level: Int) -> CGFloat {
        let basePadding = readerSettings.effectiveFontSize
        switch level {
        case 1: return basePadding * 2.0
        case 2: return basePadding * 1.8
        case 3: return basePadding * 1.5
        case 4: return basePadding * 1.2
        default: return basePadding * 1.0
        }
    }
    
    private func headingBottomPadding(for level: Int) -> CGFloat {
        let basePadding = readerSettings.effectiveFontSize
        switch level {
        case 1: return basePadding * 1.2
        case 2: return basePadding * 1.0
        case 3: return basePadding * 0.8
        case 4: return basePadding * 0.6
        default: return basePadding * 0.5
        }
    }
}

#Preview {
    SwiftUIMarkdownRenderer(
        markdownText: """
        # Heading
        
        This is **bold** and *italic* text with `inline code`.
        
        - List item 1
        - List item 2
        
        > This is a blockquote
        """,
        readerSettings: ReaderSettings()
    )
    .padding()
}
