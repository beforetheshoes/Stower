import SwiftUI
import MarkdownUI

enum ChunkContent {
    case text(String)
    case base64Image(Data, originalMarkdown: String)
    case tokenImage(UUID, alt: String, originalMarkdown: String)
}

/// Chunked lazy markdown view for optimal performance on large documents
public struct SimpleMarkdownView: View {
    let item: SavedItem
    let readerSettings: ReaderSettings
    let onChunkVisible: (Int) -> Void
    
    public init(
        item: SavedItem,
        readerSettings: ReaderSettings,
        onChunkVisible: @escaping (Int) -> Void = { _ in }
    ) {
        self.item = item
        self.readerSettings = readerSettings
        self.onChunkVisible = onChunkVisible
    }
    
    @State private var chunks: [ChunkContent] = []
    @State private var isLoadingChunks = true
    
    private func loadChunks() async {
        let content = await item.migratedMarkdown
        
        // Split by headings and large paragraphs for lazy rendering
        let components = content.components(separatedBy: "\n\n")
        
        var newChunks: [ChunkContent] = []
        var currentChunk = ""
        
        for component in components {
            // Check if this component contains an image
            if containsImage(component) {
                // Finalize current text chunk if it exists
                if !currentChunk.isEmpty {
                    newChunks.append(.text(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)))
                    currentChunk = ""
                }
                
                // Add image as separate chunk
                if let imageChunk = extractImageChunkFromMarkdown(component) {
                    newChunks.append(imageChunk)
                } else {
                    // Fallback to text if image extraction fails
                    newChunks.append(.text(component))
                }
            } else {
                // Regular text component
                if currentChunk.count + component.count > 2000 && !currentChunk.isEmpty {
                    newChunks.append(.text(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)))
                    currentChunk = component
                } else {
                    if !currentChunk.isEmpty {
                        currentChunk += "\n\n" + component
                    } else {
                        currentChunk = component
                    }
                }
            }
        }
        
        // Don't forget the last chunk
        if !currentChunk.isEmpty {
            newChunks.append(.text(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        
        // Update state on main thread
        await MainActor.run {
            self.chunks = newChunks.isEmpty ? [.text("")] : newChunks
            self.isLoadingChunks = false
        }
    }
    
    private func containsImage(_ text: String) -> Bool {
        let base64Pattern = #"!\[([^\]]*)\]\(data:image/[^;]+;base64,([^)]+)\)"#
        let tokenPattern = #"!\[([^\]]*)\]\(stower://image/([0-9a-fA-F-]{36})\)"#
        
        return text.range(of: base64Pattern, options: .regularExpression) != nil ||
               text.range(of: tokenPattern, options: .regularExpression) != nil
    }
    
    private func extractImageChunkFromMarkdown(_ markdown: String) -> ChunkContent? {
        // Try token pattern first (new format)
        let tokenPattern = #"!\[([^\]]*)\]\(stower://image/([0-9a-fA-F-]{36})\)"#
        if let tokenRegex = try? NSRegularExpression(pattern: tokenPattern, options: []) {
            let tokenMatches = tokenRegex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
            
            for match in tokenMatches {
                if match.numberOfRanges >= 3 {
                    let altRange = Range(match.range(at: 1), in: markdown)!
                    let uuidRange = Range(match.range(at: 2), in: markdown)!
                    let altText = String(markdown[altRange])
                    let uuidString = String(markdown[uuidRange])
                    
                    if let uuid = UUID(uuidString: uuidString) {
                        return .tokenImage(uuid, alt: altText, originalMarkdown: markdown)
                    }
                }
            }
        }
        
        // Fallback to base64 pattern (legacy format)
        let base64Pattern = #"!\[([^\]]*)\]\(data:image/[^;]+;base64,([^)]+)\)"#
        if let base64Regex = try? NSRegularExpression(pattern: base64Pattern, options: []) {
            let base64Matches = base64Regex.matches(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown))
            
            for match in base64Matches {
                if match.numberOfRanges >= 3 {
                    let base64Range = Range(match.range(at: 2), in: markdown)!
                    let base64String = String(markdown[base64Range])
                    if let imageData = Data(base64Encoded: base64String) {
                        return .base64Image(imageData, originalMarkdown: markdown)
                    }
                }
            }
        }
        
        return nil
    }
    
    public var body: some View {
        Group {
            if isLoadingChunks {
                ProgressView("Loading content...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                chunkView(for: chunk, at: index)
                    .onAppear {
                        onChunkVisible(index)
                        let chunkDescription = switch chunk {
                        case .text(let text):
                            "\(text.count) chars"
                        case .base64Image(let data, _):
                            "\(data.count) bytes base64 image"
                        case .tokenImage(let uuid, _, _):
                            "token image \(uuid)"
                        }
                        print("🐛 Chunk \(index) appeared (\(chunkDescription))")
                    }
                        .id("chunk_\(index)")
                    }
                }
                .padding(.horizontal)
            }
        }
        .background(readerSettings.effectiveBackground)
        .preferredColorScheme(readerSettings.effectiveColorScheme)
        .task {
            await loadChunks()
        }
    }
    
    @ViewBuilder
    private func chunkView(for chunk: ChunkContent, at index: Int) -> some View {
        switch chunk {
        case .text(let markdownText):
            Markdown(markdownText)
                .markdownTheme(.stower(settings: readerSettings, screenWidth: getScreenWidth()))
                .font(.system(size: readerSettings.effectiveFontSize, design: readerSettings.effectiveFont.fontDesign))
                
        case .base64Image(let imageData, _):
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
            
        case .tokenImage(let uuid, let alt, _):
            // Use StowerImageView for token-based images
            // Determine sizing based on cached metadata if available
            let maxHeight: CGFloat = {
                if let metadata = ImageCacheService.shared.metadata(for: uuid) {
                    let size = CGSize(width: metadata.width, height: metadata.height)
                    
                    // Apply same size classification logic as base64 images
                    if size.width <= 32 && size.height <= 32 {
                        return 24 // Small icons
                    } else if size.width <= 120 && size.height <= 120 {
                        return 60 // Simple graphics
                    } else {
                        return 400 // Full content images
                    }
                } else {
                    return 400 // Default to large if no metadata
                }
            }()
            
            StowerImageView(uuid: uuid, alt: alt, maxHeight: maxHeight)
        }
    }
    
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
    
    // MARK: - Image Classification
    
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
}

// MARK: - SwiftUI Preview

#Preview {
    SimpleMarkdownView(
        item: SavedItem.preview,
        readerSettings: ReaderSettings()
    )
}
