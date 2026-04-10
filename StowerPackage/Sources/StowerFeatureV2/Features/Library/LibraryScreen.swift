import ComposableArchitecture
import SwiftUI

public struct LibraryScreen: View {
    @Bindable var store: StoreOf<LibraryFeature>

    public init(store: StoreOf<LibraryFeature>) {
        self.store = store
    }

    public var body: some View {
        List {
            Section {
                urlComposer
                if store.saveState == .failed, let error = store.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if let error = store.errorMessage, store.saveState != .failed {
                Text(error)
                    .foregroundStyle(.red)
            }

            ForEach(store.filteredItems) { item in
                Button {
                    store.send(.openItem(item))
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        LibraryItemThumbnail(item: item)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.title)
                                    .font(.headline)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                processingBadge(item.processingState)
                            }

                            if let sourceURL = item.sourceURL,
                               let host = URL(string: sourceURL)?.host ?? Optional(sourceURL) {
                                Text(host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            HStack(spacing: 8) {
                                if let siteName = item.siteName {
                                    Label(siteName, systemImage: "globe")
                                }
                                if let reading = item.readingTimeMinutes {
                                    Label("\(reading) min", systemImage: "clock")
                                }
                                if item.hasRichMedia {
                                    Label("Rich media", systemImage: "photo.on.rectangle.angled")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading) {
                    if store.filter != .recentlyDeleted {
                        Button {
                            store.send(.toggleStar(item.id))
                        } label: {
                            Label(item.isStarred ? "Unstar" : "Star", systemImage: item.isStarred ? "star.slash" : "star.fill")
                        }
                        .tint(.yellow)

                        Button {
                            store.send(.toggleRead(item.id))
                        } label: {
                            Label(
                                item.isRead ? "Unread" : "Read",
                                systemImage: item.isRead ? "circle" : "checkmark.circle"
                            )
                        }
                        .tint(.blue)
                    } else {
                        Button {
                            store.send(.restoreFromTrash(item.id))
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if store.filter == .recentlyDeleted {
                        Button(role: .destructive) {
                            store.send(.permanentlyDelete(item.id))
                        } label: {
                            Label("Delete Forever", systemImage: "trash")
                        }
                    } else {
                        Button(role: .destructive) {
                            store.send(.deleteItem(item.id))
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            store.send(.reprocessItem(item.id))
                        } label: {
                            Label("Improve", systemImage: "wand.and.stars")
                        }
                        .tint(.purple)
                    }
                }
                .contextMenu {
                    Button("Open") {
                        store.send(.openItem(item))
                    }
                    if store.filter == .recentlyDeleted {
                        Button("Restore") {
                            store.send(.restoreFromTrash(item.id))
                        }
                        Button("Delete Forever", role: .destructive) {
                            store.send(.permanentlyDelete(item.id))
                        }
                    } else {
                        Button(item.isStarred ? "Unstar" : "Star") {
                            store.send(.toggleStar(item.id))
                        }
                        Button(item.isRead ? "Mark as Unread" : "Mark as Read") {
                            store.send(.toggleRead(item.id))
                        }
                        tagsSubmenu(for: item)
                        Button("Improve Formatting") {
                            store.send(.reprocessItem(item.id))
                        }
                        Button("Delete", role: .destructive) {
                            store.send(.deleteItem(item.id))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(navigationTitle)
        .searchable(text: $store.query.sending(\.queryChanged), prompt: "Search")
        .overlay {
            if store.isLoading {
                ProgressView()
            }
        }
        .task {
            store.send(.onAppear)
        }
    }

    @ViewBuilder
    private func tagsSubmenu(for item: SavedItem) -> some View {
        if store.availableTags.isEmpty {
            Button("Tags…", systemImage: "tag") { }
                .disabled(true)
        } else {
            Menu {
                ForEach(store.availableTags) { tag in
                    Button {
                        store.send(.toggleTagOnItem(item.id, tag.id))
                    } label: {
                        if item.tagIDs.contains(tag.id) {
                            Label(tag.name, systemImage: "checkmark")
                        } else {
                            Text(tag.name)
                        }
                    }
                }
            } label: {
                Label("Tags", systemImage: "tag")
            }
        }
    }

    private var navigationTitle: String {
        switch store.filter {
        case .all: return "All"
        case .unread: return "Unread"
        case .read: return "Read"
        case .starred: return "Starred"
        case .untagged: return "Untagged"
        case .recentlyDeleted: return "Recently Deleted"
        case .tag: return "Tag"
        }
    }

    @ViewBuilder
    private var urlComposer: some View {
        HStack(spacing: 10) {
            TextField("Paste Source URL", text: $store.sourceURL.sending(\.sourceURLChanged))
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .onSubmit { store.send(.saveURLTapped) }

            Button {
                store.send(.saveURLTapped)
            } label: {
                if store.isSaving {
                    ProgressView()
                } else {
                    Label("Add URL", systemImage: "plus.circle.fill")
                }
            }
            .disabled(store.isSaving)
            #if os(macOS)
            .buttonStyle(.borderedProminent)
            #endif
        }
    }

    private func processingBadge(_ state: ProcessingState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeBackground(state), in: Capsule())
            .foregroundStyle(badgeForeground(state))
    }

    private func badgeBackground(_ state: ProcessingState) -> Color {
        switch state {
        case .ready: return .green.opacity(0.16)
        case .partial: return .orange.opacity(0.16)
        case .failed: return .red.opacity(0.16)
        case .extracting: return .blue.opacity(0.16)
        case .queued: return .gray.opacity(0.16)
        }
    }

    private func badgeForeground(_ state: ProcessingState) -> Color {
        switch state {
        case .ready: return .green
        case .partial: return .orange
        case .failed: return .red
        case .extracting: return .blue
        case .queued: return .secondary
        }
    }
}

// MARK: - Library Item Thumbnail

private struct LibraryItemThumbnail: View {
    let item: SavedItem

    private static let size: CGFloat = 72

    var body: some View {
        Group {
            if let url = resolvedImageURL {
                CachedImageView(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        placeholder
                            .overlay { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(.secondary.opacity(0.45))
        }
    }

    private var resolvedImageURL: URL? {
        guard let heroURLString = item.heroImageURL, !heroURLString.isEmpty else {
            return nil
        }
        return URL(string: heroURLString)
    }
}
