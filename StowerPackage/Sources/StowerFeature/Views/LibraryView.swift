import SwiftUI
import SwiftData

public struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var loadedItems: [SavedItem] = []
    @State private var isLoading = false
    @State private var hasMoreItems = true
    
    // Pagination state
    private let itemsPerPage = 50
    @State private var currentOffset = 0
    
    private var filteredItems: [SavedItem] {
        var items = loadedItems
        
        if !searchText.isEmpty {
            items = items.filter { item in
                item.title.localizedCaseInsensitiveContains(searchText) ||
                item.contentPreview.localizedCaseInsensitiveContains(searchText) || // Use preview instead of full markdown
                item.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        
        if let selectedTag = selectedTag {
            items = items.filter { $0.tags.contains(selectedTag) }
        }
        
        return items
    }
    
    private var allTags: [String] {
        Array(Set(loadedItems.flatMap(\.tags))).sorted()
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !allTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            TagFilterButton(
                                title: "All",
                                isSelected: selectedTag == nil
                            ) {
                                selectedTag = nil
                            }
                            
                            ForEach(allTags, id: \.self) { tag in
                                TagFilterButton(
                                    title: tag,
                                    isSelected: selectedTag == tag
                                ) {
                                    selectedTag = selectedTag == tag ? nil : tag
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 8)
                }
                
                List {
                    ForEach(filteredItems) { item in
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
                    
                    // Load More button
                    if hasMoreItems && !searchText.isEmpty == false { // Only show when not searching
                        LoadMoreButton(isLoading: isLoading) {
                            Task {
                                await loadMoreItems()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search articles...")
            .onAppear {
                if loadedItems.isEmpty {
                    Task {
                        await loadInitialItems()
                    }
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadInitialItems() async {
        await MainActor.run {
            isLoading = true
        }
        
        do {
            // Use FetchDescriptor with propertiesToFetch for optimal performance
            var descriptor = FetchDescriptor<SavedItem>(
                sortBy: [SortDescriptor(\SavedItem.dateModified, order: .reverse)]
            )
            descriptor.fetchLimit = itemsPerPage
            descriptor.fetchOffset = 0
            
            // Only fetch lightweight properties for list display
            descriptor.propertiesToFetch = [
                \SavedItem.id,
                \SavedItem.title,
                \SavedItem.author,
                \SavedItem.url,
                \SavedItem.dateAdded,
                \SavedItem.dateModified,
                \SavedItem.tags,
                \SavedItem.coverImageId,
                \SavedItem.contentPreview
                // Note: extractedMarkdown and images are external storage - loaded only when needed
            ]
            
            let items = try modelContext.fetch(descriptor)
            
            await MainActor.run {
                loadedItems = items
                currentOffset = items.count
                hasMoreItems = items.count == itemsPerPage
                isLoading = false
            }
            
            print("📚 Loaded \(items.count) items with lightweight fetch")
        } catch {
            await MainActor.run {
                isLoading = false
            }
            print("❌ Failed to load items: \(error)")
        }
    }
    
    private func loadMoreItems() async {
        guard !isLoading && hasMoreItems else { return }
        
        await MainActor.run {
            isLoading = true
        }
        
        do {
            var descriptor = FetchDescriptor<SavedItem>(
                sortBy: [SortDescriptor(\SavedItem.dateModified, order: .reverse)]
            )
            descriptor.fetchLimit = itemsPerPage
            descriptor.fetchOffset = currentOffset
            descriptor.propertiesToFetch = [
                \SavedItem.id,
                \SavedItem.title,
                \SavedItem.author,
                \SavedItem.url,
                \SavedItem.dateAdded,
                \SavedItem.dateModified,
                \SavedItem.tags,
                \SavedItem.coverImageId,
                \SavedItem.contentPreview
            ]
            
            let newItems = try modelContext.fetch(descriptor)
            
            await MainActor.run {
                loadedItems.append(contentsOf: newItems)
                currentOffset += newItems.count
                hasMoreItems = newItems.count == itemsPerPage
                isLoading = false
            }
            
            print("📚 Loaded \(newItems.count) more items (total: \(loadedItems.count))")
        } catch {
            await MainActor.run {
                isLoading = false
            }
            print("❌ Failed to load more items: \(error)")
        }
    }
    
    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let item = filteredItems[index]
                modelContext.delete(item)
                // Remove from loaded items as well
                if let loadedIndex = loadedItems.firstIndex(where: { $0.id == item.id }) {
                    loadedItems.remove(at: loadedIndex)
                    currentOffset = max(0, currentOffset - 1)
                }
            }
        }
    }
    
    private func deleteItem(_ item: SavedItem) {
        withAnimation {
            modelContext.delete(item)
            // Remove from loaded items as well
            if let loadedIndex = loadedItems.firstIndex(where: { $0.id == item.id }) {
                loadedItems.remove(at: loadedIndex)
                currentOffset = max(0, currentOffset - 1)
            }
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

private struct TagFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.accentColor : Color.gray.opacity(0.2),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct SavedItemRow: View {
    let item: SavedItem
    
    var body: some View {
        HStack(spacing: 12) {
            // Use simple placeholder - don't access external storage data in list rows
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                
                if !item.author.isEmpty {
                    Text("by \(item.author)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                if let url = item.url {
                    Text(url.host() ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text(item.dateModified.formatAsTimestamp())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                }
                
                if !item.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(item.tags.prefix(3)), id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            
                            if item.tags.count > 3 {
                                Text("+\(item.tags.count - 3)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Load More Button Component

private struct LoadMoreButton: View {
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                } else {
                    Image(systemName: "arrow.down.circle")
                    Text("Load More")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .disabled(isLoading)
        .buttonStyle(PlainButtonStyle())
    }
}