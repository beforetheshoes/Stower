import SwiftUI
import SwiftData
import MarkdownUI

public struct ReaderView: View {
    let itemId: UUID
    
    @Query private var items: [SavedItem]
    @State private var readerSettings = ReaderSettings()
    @State private var hasScrolledToLastPosition = false
    @State private var currentChunkIndex = 0
    
    public init(itemId: UUID) {
        self.itemId = itemId
        
        // Create a targeted query for this specific item
        let predicate = #Predicate<SavedItem> { item in
            item.id == itemId
        }
        _items = Query(filter: predicate)
    }
    
    private var item: SavedItem? {
        items.first
    }
    
    public var body: some View {
        Group {
            if let item = item {
                ScrollViewReader { proxy in
                    ScrollView {
                        SimpleMarkdownView(
                            item: item,
                            readerSettings: readerSettings,
                            onChunkVisible: { chunkIndex in
                                // Only update state if the value actually changed
                                if currentChunkIndex != chunkIndex {
                                    currentChunkIndex = chunkIndex
                                }
                                
                                // Trigger scroll restoration only once when the exact target chunk appears
                                if !hasScrolledToLastPosition && item.lastReadChunkIndex > 0 && chunkIndex == item.lastReadChunkIndex {
                                    print("🔄 Exact target chunk \(item.lastReadChunkIndex) appeared, attempting scroll restoration")
                                    hasScrolledToLastPosition = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation(.easeInOut(duration: 0.5)) {
                                            proxy.scrollTo("chunk_\(item.lastReadChunkIndex)", anchor: .top)
                                        }
                                    }
                                }
                            }
                        )
                    }
                    .onAppear {
                        print("📖 ReaderView appeared - LastReadChunkIndex: \(item.lastReadChunkIndex)")
                        
                        // Only try initial scroll if we haven't already scrolled and have a saved position
                        if !hasScrolledToLastPosition && item.lastReadChunkIndex > 0 {
                            print("🔄 Attempting initial scroll restoration to chunk \(item.lastReadChunkIndex)")
                            
                            // Try immediate scroll first (for chunks that render quickly)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    proxy.scrollTo("chunk_\(item.lastReadChunkIndex)", anchor: .top)
                                }
                                hasScrolledToLastPosition = true
                                print("✅ Initial scroll restoration completed")
                            }
                        } else if item.lastReadChunkIndex == 0 {
                            print("📄 Starting from beginning - no scroll restoration needed")
                            hasScrolledToLastPosition = true
                        }
                    }
                }
                .navigationTitle(item.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            } else {
                let _ = print("🐛 ReaderView: No item found for ID: \(itemId)")
                ContentUnavailableView(
                    "Article Not Found",
                    systemImage: "doc.text",
                    description: Text("The article you're looking for could not be found.")
                )
            }
        }
        .onAppear {
            print("🐛 ReaderView: ReaderView appeared, looking for item ID: \(itemId)")
            hasScrolledToLastPosition = false
        }
        .onDisappear {
            print("📖 ReaderView disappeared - saving scroll position: \(currentChunkIndex)")
            // Save scroll position when leaving the view to avoid constant SwiftData updates
            if let item = item {
                item.lastReadChunkIndex = currentChunkIndex
            }
        }
    }
}