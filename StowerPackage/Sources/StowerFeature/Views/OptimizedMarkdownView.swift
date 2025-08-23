import SwiftUI
import MarkdownUI

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
    
    private var cleanMarkdown: String {
        // Images now stripped at extraction time, no need for regex processing
        return item.extractedMarkdown
    }
    
    private var chunks: [String] {
        let content = cleanMarkdown
        
        // Split by headings and large paragraphs for lazy rendering
        _ = #"\n(#{1,6}\s+.*?)(?=\n|\Z)"#
        let components = content.components(separatedBy: "\n\n")
        
        var chunks: [String] = []
        var currentChunk = ""
        
        for component in components {
            // If adding this component would make the chunk too large, finalize current chunk
            if currentChunk.count + component.count > 2000 && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = component
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += "\n\n" + component
                } else {
                    currentChunk = component
                }
            }
        }
        
        // Don't forget the last chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return chunks.isEmpty ? [""] : chunks
    }
    
    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                Markdown(chunk)
                    .font(.body)
                    .onAppear {
                        onChunkVisible(index)
                        print("🐛 Chunk \(index) appeared (\(chunk.count) chars)")
                    }
                    .id("chunk_\(index)")
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - SwiftUI Preview

#Preview {
    SimpleMarkdownView(
        item: SavedItem.preview,
        readerSettings: ReaderSettings()
    )
}
