import SwiftUI

public struct CustomMarkdownView: View {
    private let markdown: String
    private let images: [UUID: Data]
    private let readerSettings: ReaderSettings
    @Binding private var isEditMode: Bool
    private let onContentChanged: (String) -> Void
    @State private var selectedSections: Set<Int> = []
    @State private var processedSections: [MarkdownSection] = []
    
    public init(
        markdown: String, 
        images: [UUID: Data], 
        readerSettings: ReaderSettings,
        isEditMode: Binding<Bool> = .constant(false),
        onContentChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.markdown = markdown
        self.images = images
        self.readerSettings = readerSettings
        self._isEditMode = isEditMode
        self.onContentChanged = onContentChanged
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Show edit controls when in edit mode
            if isEditMode && !selectedSections.isEmpty {
                editControls
            }
            
            // Parse markdown and insert images at proper positions
            ForEach(Array(processedSections.enumerated()), id: \.offset) { index, section in
                sectionView(for: section, at: index, screenWidth: getScreenWidth())
            }
        }
        .font(.system(size: readerSettings.effectiveFontSize, design: readerSettings.effectiveFont.fontDesign))
        .background(readerSettings.effectiveBackground)
        .onAppear {
            // Use async processing for large markdown content
            if markdown.count > 10000 {
                Task {
                    let sections = await asyncParseMarkdownWithImages()
                    await MainActor.run {
                        processedSections = sections
                    }
                }
            } else {
                processedSections = parseMarkdownWithImages()
            }
        }
        .onChange(of: markdown) { _, _ in
            // Clear sections immediately for responsiveness
            processedSections = []
            selectedSections.removeAll()
            
            // Process new content
            if markdown.count > 10000 {
                Task {
                    let sections = await asyncParseMarkdownWithImages()
                    await MainActor.run {
                        processedSections = sections
                    }
                }
            } else {
                processedSections = parseMarkdownWithImages()
            }
        }
    }
    
    @ViewBuilder
    private var editControls: some View {
        HStack {
            Button("Delete Selected (\(selectedSections.count))") {
                deleteSelectedSections()
            }
            .buttonStyle(.borderedProminent)
            .foregroundColor(.white)
            .background(.red)
            
            Spacer()
            
            Button("Cancel") {
                selectedSections.removeAll()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func sectionView(for section: MarkdownSection, at index: Int, screenWidth: CGFloat) -> some View {
        let isSelected = selectedSections.contains(index)
        
        Group {
            switch section {
            case .text(let markdownText):
                SwiftUIMarkdownRenderer(markdownText: markdownText, readerSettings: readerSettings)
            case .image(let imageData, _):
#if os(iOS)
                if let uiImage = UIImage(data: imageData) {
                    let isSmallIcon = isSmallDecorativeImage(uiImage)
                    let isSimpleGraphic = isSimpleGraphic(uiImage)
                    
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: {
                            if isSmallIcon {
                                return 24 // Small icons like person icons
                            } else if isSimpleGraphic {
                                return 60 // Simple graphics like tags
                            } else {
                                return 400 // Full content images
                            }
                        }())
                        .cornerRadius(isSmallIcon ? 4 : 12)
                        .shadow(color: .black.opacity(isSmallIcon ? 0.05 : 0.1), 
                               radius: isSmallIcon ? 2 : 8, 
                               x: 0, 
                               y: isSmallIcon ? 1 : 4)
                        .padding(.vertical, isSmallIcon ? 2 : 8)
                }
#elseif os(macOS)
                if let nsImage = NSImage(data: imageData) {
                    let isSmallIcon = isSmallDecorativeImage(nsImage)
                    let isSimpleGraphic = isSimpleGraphic(nsImage)
                    
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: {
                            if isSmallIcon {
                                return 24 // Small icons like person icons
                            } else if isSimpleGraphic {
                                return 60 // Simple graphics like tags
                            } else {
                                return 400 // Full content images
                            }
                        }())
                        .cornerRadius(isSmallIcon ? 4 : 12)
                        .shadow(color: .black.opacity(isSmallIcon ? 0.05 : 0.1), 
                               radius: isSmallIcon ? 2 : 8, 
                               x: 0, 
                               y: isSmallIcon ? 1 : 4)
                        .padding(.vertical, isSmallIcon ? 2 : 8)
                }
#endif
            case .callout(let type, let content):
                CalloutView(type: type, content: content, readerSettings: readerSettings)
                    .padding(.vertical, 4) // Extra space around callouts
            }
        }
        .overlay(
            // Selection overlay in edit mode
            isEditMode ? RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.red : Color.blue.opacity(0.3), lineWidth: isSelected ? 3 : 1)
                .background(isSelected ? Color.red.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                : nil
        )
        .onTapGesture {
            if isEditMode {
                if isSelected {
                    selectedSections.remove(index)
                } else {
                    selectedSections.insert(index)
                }
            }
        }
    }
    
    private func deleteSelectedSections() {
        // Remove sections in reverse order to maintain indices
        let sortedIndices = selectedSections.sorted(by: >)
        
        for index in sortedIndices {
            if index < processedSections.count {
                processedSections.remove(at: index)
            }
        }
        
        // Convert back to markdown and notify parent
        let updatedMarkdown = reconstructMarkdown(from: processedSections)
        onContentChanged(updatedMarkdown)
        
        // Clear selection
        selectedSections.removeAll()
    }
    
    private func reconstructMarkdown(from sections: [MarkdownSection]) -> String {
        var markdownParts: [String] = []
        
        for section in sections {
            switch section {
            case .text(let text):
                markdownParts.append(text)
            case .image(_, let originalMarkdown):
                // Preserve the original image markdown
                markdownParts.append(originalMarkdown)
            case .callout(_, let content):
                // Preserve original callout formatting
                markdownParts.append(content)
            }
        }
        
        return markdownParts.joined(separator: "\n\n")
    }
    
    enum MarkdownSection {
        case text(String)
        case image(Data, originalMarkdown: String)
        case callout(type: CalloutType, content: String)
    }
    
    
    private func parseMarkdownWithImages() -> [MarkdownSection] {
        // Remove title from markdown since it's already displayed in the header
        let markdownWithoutTitle = removeTitleFromMarkdown(markdown)
        
        // Parse into paragraph-level sections for more predictable editing
        return parseParagraphSections(markdownWithoutTitle)
    }
    
    private func asyncParseMarkdownWithImages() async -> [MarkdownSection] {
        let markdownCopy = markdown
        return await Task.detached(priority: .utility) {
            // Create a temporary instance to access the parsing methods
            let parser = MarkdownParser(markdown: markdownCopy)
            return parser.parseMarkdownInBackground()
        }.value
    }
    
    private func parseParagraphSections(_ text: String) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        
        // Split by double newlines to get paragraph-level sections
        let paragraphs = text.components(separatedBy: "\n\n")
        
        for paragraph in paragraphs {
            let trimmedParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedParagraph.isEmpty { continue }
            
            // Check if this paragraph contains an image
            let imagePattern = "!\\[([^\\]]*)\\]\\(data:image/[^;]+;base64,([^)]+)\\)"
            let regex = try! NSRegularExpression(pattern: imagePattern, options: [])
            let imageMatches = regex.matches(in: trimmedParagraph, options: [], range: NSRange(trimmedParagraph.startIndex..., in: trimmedParagraph))
            
            if !imageMatches.isEmpty {
                // This paragraph contains images - extract them
                for match in imageMatches {
                    if match.numberOfRanges >= 3 {
                        let base64Range = Range(match.range(at: 2), in: trimmedParagraph)!
                        let base64String = String(trimmedParagraph[base64Range])
                        
                        if let imageData = Data(base64Encoded: base64String) {
                            // Store both the image data and original markdown
                            sections.append(.image(imageData, originalMarkdown: trimmedParagraph))
                        }
                    }
                }
            } else if isCalloutParagraph(trimmedParagraph) {
                // This is a callout paragraph
                if let callout = parseCalloutFromParagraph(trimmedParagraph) {
                    sections.append(.callout(type: callout.type, content: callout.content))
                }
            } else {
                // Regular text paragraph
                sections.append(.text(trimmedParagraph))
            }
        }
        
        return sections.isEmpty ? [.text(text)] : sections
    }
    
    private func isCalloutParagraph(_ paragraph: String) -> Bool {
        let lines = paragraph.components(separatedBy: .newlines)
        let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        // Check for blockquote callouts
        if firstLine.hasPrefix("> ") {
            let content = String(firstLine.dropFirst(2)).lowercased()
            let warningIndicators = ["⚠️", "🚨", "❗", "warning", "caution", "note", "important", "tip"]
            return warningIndicators.contains { content.contains($0.lowercased()) }
        }
        
        // Check for standalone callout indicators
        let warningIndicators = ["⚠️", "🚨", "❗", "💡", "📝", "ℹ️"]
        return warningIndicators.contains { firstLine.hasPrefix($0) } ||
               firstLine.lowercased().hasPrefix("warning:") ||
               firstLine.lowercased().hasPrefix("note:") ||
               firstLine.lowercased().hasPrefix("tip:")
    }
    
    private func parseCalloutFromParagraph(_ paragraph: String) -> (type: CalloutType, content: String)? {
        let lines = paragraph.components(separatedBy: .newlines)
        let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        var calloutType: CalloutType = .note
        
        // Determine callout type
        if firstLine.contains("⚠️") || firstLine.contains("🚨") || firstLine.lowercased().contains("warning") {
            calloutType = .warning
        } else if firstLine.contains("❗") || firstLine.lowercased().contains("caution") {
            calloutType = .caution
        } else if firstLine.contains("💡") || firstLine.lowercased().contains("tip") {
            calloutType = .tip
        } else if firstLine.contains("📝") || firstLine.lowercased().contains("note") {
            calloutType = .note
        } else if firstLine.contains("ℹ️") {
            calloutType = .info
        }
        
        return (type: calloutType, content: paragraph)
    }
    
    private func removeTitleFromMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var resultLines: [String] = []
        var foundTitle = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip the first H1 heading (title)
            if !foundTitle && trimmedLine.hasPrefix("# ") {
                foundTitle = true
                continue
            }
            
            // Skip empty lines immediately after the title
            if foundTitle && trimmedLine.isEmpty && resultLines.isEmpty {
                continue
            }
            
            resultLines.append(line)
        }
        
        return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func processContentSections(_ text: String) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        
        // First, split by images to handle them properly
        let imagePattern = "!\\[([^\\]]*)\\]\\(data:image/[^;]+;base64,([^)]+)\\)"
        let regex = try! NSRegularExpression(pattern: imagePattern, options: [])
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        
        var lastEndIndex = text.startIndex
        
        for match in matches {
            // Process text before image (this may contain callouts)
            if match.range.location > text.distance(from: text.startIndex, to: lastEndIndex) {
                let textRange = lastEndIndex..<text.index(text.startIndex, offsetBy: match.range.location)
                let textSection = String(text[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !textSection.isEmpty {
                    // Process this text section for callouts
                    let calloutSections = processCallouts(in: textSection)
                    sections.append(contentsOf: calloutSections)
                }
            }
            
            // Extract and decode base64 image
            if match.numberOfRanges >= 3 {
                let base64Range = Range(match.range(at: 2), in: text)!
                let base64String = String(text[base64Range])
                
                if let imageData = Data(base64Encoded: base64String) {
                    // Extract the full image markdown
                    let imageRange = Range(match.range, in: text)!
                    let originalMarkdown = String(text[imageRange])
                    sections.append(.image(imageData, originalMarkdown: originalMarkdown))
                }
            }
            
            lastEndIndex = text.index(text.startIndex, offsetBy: match.range.location + match.range.length)
        }
        
        // Process remaining text (this may contain callouts)
        if lastEndIndex < text.endIndex {
            let remainingText = String(text[lastEndIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingText.isEmpty {
                let calloutSections = processCallouts(in: remainingText)
                sections.append(contentsOf: calloutSections)
            }
        }
        
        // If no images were found, process the entire text for callouts
        if matches.isEmpty {
            let calloutSections = processCallouts(in: text)
            sections.append(contentsOf: calloutSections)
        }
        
        return sections
    }
    
    private func processCallouts(in text: String) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        
        // Look for both blockquotes and standalone lines with warning indicators
        let lines = text.components(separatedBy: .newlines)
        var processedLines: [String] = []
        var i = 0
        
        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if this line starts a blockquote with warning indicators
            if line.hasPrefix("> ") {
                let content = String(line.dropFirst(2))
                
                // Look for warning indicators at the start of blockquotes
                let warningIndicators = ["⚠️", "🚨", "❗", "warning", "caution", "note", "important", "tip"]
                let lowerContent = content.lowercased()
                
                var isCallout = false
                var calloutType: CalloutType = .note
                
                // Check if this blockquote contains warning indicators
                for indicator in warningIndicators {
                    if lowerContent.contains(indicator.lowercased()) {
                        isCallout = true
                        // Map common words to callout types
                        switch indicator.lowercased() {
                        case "warning", "⚠️", "🚨":
                            calloutType = .warning
                        case "caution", "❗":
                            calloutType = .caution
                        case "note", "📝":
                            calloutType = .note
                        case "important":
                            calloutType = .important
                        case "tip", "💡":
                            calloutType = .tip
                        default:
                            calloutType = .note
                        }
                        break
                    }
                }
                
                if isCallout {
                    // Collect all lines of this blockquote
                    var blockquoteLines: [String] = [content]
                    var j = i + 1
                    
                    while j < lines.count && lines[j].hasPrefix("> ") {
                        blockquoteLines.append(String(lines[j].dropFirst(2)))
                        j += 1
                    }
                    
                    // Add any text before this callout
                    if !processedLines.isEmpty {
                        let textContent = processedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !textContent.isEmpty {
                            sections.append(.text(textContent))
                        }
                        processedLines.removeAll()
                    }
                    
                    // Add the callout
                    let calloutContent = blockquoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    sections.append(.callout(type: calloutType, content: calloutContent))
                    
                    // Skip past this blockquote
                    i = j
                    continue
                }
            }
            // NEW: Also check for standalone lines that start with warning indicators
            else if !trimmedLine.isEmpty {
                let warningIndicators = ["⚠️", "🚨", "❗", "💡", "📝", "ℹ️"]
                let lowerLine = trimmedLine.lowercased()
                
                var isCallout = false
                var calloutType: CalloutType = .note
                
                // Check if this line starts with a warning indicator
                for indicator in warningIndicators {
                    if trimmedLine.hasPrefix(indicator) || lowerLine.hasPrefix("warning:") || lowerLine.hasPrefix("note:") || lowerLine.hasPrefix("tip:") {
                        isCallout = true
                        switch indicator {
                        case "⚠️", "🚨":
                            calloutType = .warning
                        case "❗":
                            calloutType = .caution
                        case "💡":
                            calloutType = .tip
                        case "📝":
                            calloutType = .note
                        case "ℹ️":
                            calloutType = .info
                        default:
                            calloutType = .note
                        }
                        
                        // Also check for text-based indicators
                        if lowerLine.hasPrefix("warning:") {
                            calloutType = .warning
                        } else if lowerLine.hasPrefix("note:") {
                            calloutType = .note
                        } else if lowerLine.hasPrefix("tip:") {
                            calloutType = .tip
                        }
                        
                        break
                    }
                }
                
                if isCallout {
                    // Add any text before this callout
                    if !processedLines.isEmpty {
                        let textContent = processedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !textContent.isEmpty {
                            sections.append(.text(textContent))
                        }
                        processedLines.removeAll()
                    }
                    
                    // Collect the callout content (this line plus following lines until empty line or next indicator)
                    var calloutLines: [String] = [trimmedLine]
                    var j = i + 1
                    
                    // Look ahead for continuation lines
                    while j < lines.count {
                        let nextLine = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Stop if we hit an empty line or another callout indicator
                        if nextLine.isEmpty {
                            break
                        }
                        
                        // Stop if this line starts with another indicator
                        var isAnotherCallout = false
                        for indicator in warningIndicators {
                            if nextLine.hasPrefix(indicator) {
                                isAnotherCallout = true
                                break
                            }
                        }
                        
                        if isAnotherCallout {
                            break
                        }
                        
                        // Add this line to the callout content
                        calloutLines.append(nextLine)
                        j += 1
                    }
                    
                    // Add the multi-line callout
                    let calloutContent = calloutLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    sections.append(.callout(type: calloutType, content: calloutContent))
                    
                    // Skip past all collected lines
                    i = j
                    continue
                }
            }
            
            processedLines.append(line)
            i += 1
        }
        
        // Add any remaining text as a text section
        if !processedLines.isEmpty {
            let remainingText = processedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingText.isEmpty {
                sections.append(.text(remainingText))
            }
        }
        
        return sections
    }
    
#if os(iOS)
    private func isSmallDecorativeImage(_ image: UIImage) -> Bool {
        let size = image.size
        
        // Small square images are likely icons
        if size.width <= 32 && size.height <= 32 {
            return true
        }
        
        // Very thin or very short images are likely decorative
        if size.width <= 16 || size.height <= 16 {
            return true
        }
        
        // Images that are simple black/white with limited colors
        return hasLimitedColorPalette(image)
    }
    
    private func isSimpleGraphic(_ image: UIImage) -> Bool {
        let size = image.size
        
        // Medium-sized simple graphics (like folder/tag icons)
        if size.width <= 120 && size.height <= 120 {
            return hasLimitedColorPalette(image)
        }
        
        return false
    }
    
    private func hasLimitedColorPalette(_ image: UIImage) -> Bool {
        // For now, use a simple heuristic based on size and aspect ratio
        // In a more sophisticated implementation, we could analyze the actual color palette
        let size = image.size
        let aspectRatio = size.width / size.height
        
        // Very square images or very thin images are often icons
        if (aspectRatio > 0.8 && aspectRatio < 1.2) || aspectRatio > 5 || aspectRatio < 0.2 {
            return true
        }
        
        // Small images are likely simple graphics
        return size.width * size.height < 10000 // Less than ~100x100 pixels
    }
#elseif os(macOS)
    private func isSmallDecorativeImage(_ image: NSImage) -> Bool {
        let size = image.size
        
        // Small square images are likely icons
        if size.width <= 32 && size.height <= 32 {
            return true
        }
        
        // Very thin or very short images are likely decorative
        if size.width <= 16 || size.height <= 16 {
            return true
        }
        
        // Images that are simple black/white with limited colors
        return hasLimitedColorPalette(image)
    }
    
    private func isSimpleGraphic(_ image: NSImage) -> Bool {
        let size = image.size
        
        // Medium-sized simple graphics (like folder/tag icons)
        if size.width <= 120 && size.height <= 120 {
            return hasLimitedColorPalette(image)
        }
        
        return false
    }
    
    private func hasLimitedColorPalette(_ image: NSImage) -> Bool {
        // For now, use a simple heuristic based on size and aspect ratio
        // In a more sophisticated implementation, we could analyze the actual color palette
        let size = image.size
        let aspectRatio = size.width / size.height
        
        // Very square images or very thin images are often icons
        if (aspectRatio > 0.8 && aspectRatio < 1.2) || aspectRatio > 5 || aspectRatio < 0.2 {
            return true
        }
        
        // Small images are likely simple graphics
        return size.width * size.height < 10000 // Less than ~100x100 pixels
    }
#endif
    
    // MARK: - Helper Functions
    
    private func getScreenWidth() -> CGFloat {
        #if os(iOS)
        return UIScreen.main.bounds.width
        #elseif os(macOS)
        if let screen = NSScreen.main {
            return screen.frame.width
        }
        return 1024 // Default fallback
        #else
        return 1024 // Default fallback
        #endif
    }
}

// MARK: - Background Markdown Parser

private struct MarkdownParser {
    let markdown: String
    
    func parseMarkdownInBackground() -> [CustomMarkdownView.MarkdownSection] {
        // Remove title from markdown since it's already displayed in the header
        let markdownWithoutTitle = removeTitleFromMarkdown(markdown)
        
        // Parse into paragraph-level sections for more predictable editing
        return parseParagraphSections(markdownWithoutTitle)
    }
    
    private func removeTitleFromMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var resultLines: [String] = []
        var foundTitle = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip the first H1 heading (title)
            if !foundTitle && trimmedLine.hasPrefix("# ") {
                foundTitle = true
                continue
            }
            
            // Skip empty lines immediately after the title
            if foundTitle && trimmedLine.isEmpty && resultLines.isEmpty {
                continue
            }
            
            resultLines.append(line)
        }
        
        return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func parseParagraphSections(_ text: String) -> [CustomMarkdownView.MarkdownSection] {
        var sections: [CustomMarkdownView.MarkdownSection] = []
        
        // Split by double newlines to get paragraph-level sections
        let paragraphs = text.components(separatedBy: "\n\n")
        
        for paragraph in paragraphs {
            let trimmedParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedParagraph.isEmpty { continue }
            
            // Check if this paragraph contains an image
            let imagePattern = "!\\[([^\\]]*)\\]\\(data:image/[^;]+;base64,([^)]+)\\)"
            guard let regex = try? NSRegularExpression(pattern: imagePattern, options: []) else {
                sections.append(.text(trimmedParagraph))
                continue
            }
            
            let imageMatches = regex.matches(in: trimmedParagraph, options: [], range: NSRange(trimmedParagraph.startIndex..., in: trimmedParagraph))
            
            if !imageMatches.isEmpty {
                // This paragraph contains images - extract them
                for match in imageMatches {
                    if match.numberOfRanges >= 3 {
                        let base64Range = Range(match.range(at: 2), in: trimmedParagraph)!
                        let base64String = String(trimmedParagraph[base64Range])
                        
                        if let imageData = Data(base64Encoded: base64String) {
                            // Store both the image data and original markdown
                            sections.append(.image(imageData, originalMarkdown: trimmedParagraph))
                        }
                    }
                }
            } else if isCalloutParagraph(trimmedParagraph) {
                // This is a callout paragraph
                if let callout = parseCalloutFromParagraph(trimmedParagraph) {
                    sections.append(.callout(type: callout.type, content: callout.content))
                }
            } else {
                // Regular text paragraph
                sections.append(.text(trimmedParagraph))
            }
        }
        
        return sections.isEmpty ? [.text(text)] : sections
    }
    
    private func isCalloutParagraph(_ paragraph: String) -> Bool {
        let lines = paragraph.components(separatedBy: .newlines)
        let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        // Check for blockquote callouts
        if firstLine.hasPrefix("> ") {
            let content = String(firstLine.dropFirst(2)).lowercased()
            let warningIndicators = ["⚠️", "🚨", "❗", "warning", "caution", "note", "important", "tip"]
            return warningIndicators.contains { content.contains($0.lowercased()) }
        }
        
        // Check for standalone callout indicators
        let warningIndicators = ["⚠️", "🚨", "❗", "💡", "📝", "ℹ️"]
        return warningIndicators.contains { firstLine.hasPrefix($0) } ||
               firstLine.lowercased().hasPrefix("warning:") ||
               firstLine.lowercased().hasPrefix("note:") ||
               firstLine.lowercased().hasPrefix("tip:")
    }
    
    private func parseCalloutFromParagraph(_ paragraph: String) -> (type: CalloutType, content: String)? {
        let lines = paragraph.components(separatedBy: .newlines)
        let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        var calloutType: CalloutType = .note
        
        // Determine callout type
        if firstLine.contains("⚠️") || firstLine.contains("🚨") || firstLine.lowercased().contains("warning") {
            calloutType = .warning
        } else if firstLine.contains("❗") || firstLine.lowercased().contains("caution") {
            calloutType = .caution
        } else if firstLine.contains("💡") || firstLine.lowercased().contains("tip") {
            calloutType = .tip
        } else if firstLine.contains("📝") || firstLine.lowercased().contains("note") {
            calloutType = .note
        } else if firstLine.contains("ℹ️") {
            calloutType = .info
        }
        
        return (type: calloutType, content: paragraph)
    }
}