import ComposableArchitecture
import SwiftUI

public struct LibraryScreen: View {
    @Bindable var store: StoreOf<LibraryFeature>
    /// Invoked when the user taps the settings gear in the iOS toolbar.
    /// nil on macOS (the sidebar already has its own settings button).
    private let onOpenSettings: (() -> Void)?
    @State private var isAddURLPresented = false

    public init(
        store: StoreOf<LibraryFeature>,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        List {
            #if os(macOS)
            // On macOS the inline composer lives at the top of the list
            // because the window is wide enough that it doesn't crowd the
            // article rows. iOS moves it into a sheet triggered by the
            // toolbar "+" button so the list is clean.
            Section {
                urlComposer
                    .listRowBackground(Color.clear)
                if store.saveState == .failed, let error = store.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            }
            if let error = store.errorMessage, store.saveState != .failed {
                Text(error)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
            #endif

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
                // `List` gives every row its own opaque platter background
                // (white in light mode, near-black in dark mode) regardless
                // of `.scrollContentBackground(.hidden)` on the List itself.
                // Clearing the row background lets the parent's theme color
                // show through for Sepia/Dark/White reader themes.
                .listRowBackground(Color.clear)
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
        #if os(iOS)
        .toolbar {
            if let onOpenSettings {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Clear any stale error so the sheet starts clean.
                    if store.saveState == .failed {
                        store.send(.sourceURLChanged(""))
                    }
                    isAddURLPresented = true
                } label: {
                    Label("Add URL", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddURLPresented) {
            addURLSheet
        }
        // Auto-dismiss the "Add URL" sheet the moment a save succeeds.
        // `saveURLFinished` transitions `saveState` to `.ready` and clears
        // `sourceURL`, which is our cue that the new item is in the list.
        .onChange(of: store.saveState) { _, newValue in
            if isAddURLPresented, newValue == .ready, store.sourceURL.isEmpty {
                isAddURLPresented = false
            }
        }
        #endif
        .task {
            store.send(.onAppear)
        }
    }

    #if os(iOS)
    /// Modal URL-entry form shown when the user taps the toolbar "+".
    @ViewBuilder
    private var addURLSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "https://example.com/article",
                        text: $store.sourceURL.sending(\.sourceURLChanged)
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { store.send(.saveURLTapped) }
                } header: {
                    Text("URL")
                } footer: {
                    if store.saveState == .failed, let error = store.errorMessage {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Paste any article URL. Stower will fetch and archive it for offline reading.")
                    }
                }
            }
            .navigationTitle("Add URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isAddURLPresented = false
                    }
                    .disabled(store.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isSaving {
                        ProgressView()
                    } else {
                        Button("Add") {
                            store.send(.saveURLTapped)
                        }
                        .disabled(store.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(store.isSaving)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

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
                #if os(iOS)
                // iOS TextField defaults to `.sentences` which capitalizes
                // the first character. Without this modifier "https://…"
                // becomes "Https://…" and downstream parsers silently fail.
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
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
