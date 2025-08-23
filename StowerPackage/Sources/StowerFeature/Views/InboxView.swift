import SwiftUI
import SwiftData

extension Date {
    func formatAsTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: self)
    }
}

public struct InboxView: View {
    @Query(sort: \SavedItem.dateAdded, order: .reverse) 
    private var savedItems: [SavedItem]
    @Environment(\.modelContext) private var modelContext
    @State private var showingAddItem = false
    
    public var body: some View {
        NavigationStack {
            List {
                ForEach(savedItems) { item in
                    NavigationLink {
                        ReaderView(itemId: item.id)
                    } label: {
                        SavedItemRow(item: item)
                    }
                    .contextMenu {
                        if item.isFromURL {
                            Button {
                                refreshItem(item)
                            } label: {
                                Label("Refresh Content", systemImage: "arrow.clockwise")
                            }
                        }
                        
                        Button(role: .destructive) {
                            deleteItem(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: deleteItems)
            }
#if os(iOS)
            .navigationTitle("Inbox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        showingAddItem = true
                    }
                }
            }
#else
            // macOS doesn't need navigation title here since it's handled by the split view
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Item") {
                        showingAddItem = true
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
#endif
            .sheet(isPresented: $showingAddItem) {
                AddItemView()
            }
        }
    }
    
    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(savedItems[index])
            }
        }
    }
    
    private func deleteItem(_ item: SavedItem) {
        withAnimation {
            modelContext.delete(item)
        }
    }
    
    private func refreshItem(_ item: SavedItem) {
        guard let url = item.url else { return }
        
        Task {
            await processURL(for: item, url: url)
        }
    }
    
    @MainActor
    private func processURL(for item: SavedItem, url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            let htmlString: String?
            if let utf8String = String(data: data, encoding: .utf8) {
                htmlString = utf8String
            } else if let isoString = String(data: data, encoding: .isoLatin1) {
                htmlString = isoString
            } else if let asciiString = String(data: data, encoding: .ascii) {
                htmlString = asciiString
            } else {
                htmlString = nil
            }
            
            if let htmlString = htmlString {
                item.rawHTML = htmlString
                
                let contentService = ContentExtractionService()
                let extractedContent = try await contentService.extractContent(from: htmlString, baseURL: url)
                
                // Use native SwiftUI image handling - no custom processing needed
                item.updateContent(
                    title: extractedContent.title,
                    extractedMarkdown: extractedContent.markdown
                )
                
                try modelContext.save()
            }
        } catch {
            print("Failed to refresh item: \(error)")
        }
    }
    
    public init() {}
}

private struct SavedItemRow: View {
    let item: SavedItem
    
    var body: some View {
        HStack(spacing: 12) {
            // Use simple placeholder - don't access external storage data in list rows
            placeholderImage
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                
                if let url = item.url {
                    Text(url.host() ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text(item.dateAdded.formatAsTimestamp())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 60, height: 60)
            .overlay {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }
}