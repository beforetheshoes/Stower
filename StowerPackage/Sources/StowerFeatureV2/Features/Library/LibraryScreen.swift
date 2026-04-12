import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct LibraryScreen: View {
    @Bindable var store: StoreOf<LibraryFeature>
    @Environment(\.flexokiPalette)
    private var palette
    @Environment(\.openURL)
    private var openURL
    /// Invoked when the user taps the settings gear in the iOS toolbar.
    /// nil on macOS (the sidebar already has its own settings button).
    private let onOpenSettings: (() -> Void)?
    /// Invoked when the user taps the filter button in the iOS toolbar.
    /// nil on macOS / iPad split-view where the sidebar column is always
    /// visible. Set on iPhone compact to surface the filter sheet.
    private let onOpenFilters: (() -> Void)?
    @State private var isAddURLPresented = false
    @State private var isPDFPickerPresented = false

    public init(
        store: StoreOf<LibraryFeature>,
        onOpenSettings: (() -> Void)? = nil,
        onOpenFilters: (() -> Void)? = nil
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenFilters = onOpenFilters
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
                        .foregroundStyle(palette.error)
                        .listRowBackground(Color.clear)
                }
            }
            if let error = store.errorMessage, store.saveState != .failed {
                Text(error)
                    .foregroundStyle(palette.error)
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
                                Text(LibrarySearchHighlight.highlighted(item.title, query: store.query))
                                    .font(.headline)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // Pill is only shown for states the user
                                // might want to act on. `.ready` and
                                // `.queued` are just noise in the common
                                // case where every row in the list is
                                // already ready to read.
                                if shouldShowBadge(for: item.processingState) {
                                    processingBadge(item.processingState)
                                }
                            }

                            // When the query matches body text (not title),
                            // surface the hit as a snippet so the user can
                            // tell why the row showed up in results. Nil
                            // when the title already contains the match —
                            // no need to duplicate the context.
                            if let snippet = LibrarySearchHighlight.bodySnippet(
                                item: item,
                                query: store.query
                            ) {
                                Text(snippet)
                                    .font(.caption)
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        .tint(palette.warning)

                        Button {
                            store.send(.toggleRead(item.id))
                        } label: {
                            Label(
                                item.isRead ? "Unread" : "Read",
                                systemImage: item.isRead ? "circle" : "checkmark.circle"
                            )
                        }
                        .tint(palette.primary)
                    } else {
                        Button {
                            store.send(.restoreFromTrash(item.id))
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(palette.success)
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
                        .tint(palette.secondary)
                    }
                }
                .contextMenu {
                    Button("Open") {
                        store.send(.openItem(item))
                    }
                    if let sourceURLString = item.sourceURL,
                       let sourceURL = URL(string: sourceURLString) {
                        Button("Open Original URL") {
                            openURL(sourceURL)
                        }
                        Button("Copy Original URL") {
                            copyToClipboard(sourceURLString)
                        }
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
        // Obscure rows as they scroll behind the Liquid Glass nav bar so
        // the first row stays legible against the glass material.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(navigationTitle)
        .searchable(text: $store.query.sending(\.queryChanged), prompt: "Search")
        .overlay {
            if store.isLoading {
                ProgressView()
            }
        }
        #if os(iOS)
        .toolbar {
            if let onOpenFilters {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onOpenFilters()
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
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
                Menu {
                    Button {
                        if store.saveState == .failed {
                            store.send(.sourceURLChanged(""))
                        }
                        isAddURLPresented = true
                    } label: {
                        Label("Add URL…", systemImage: "link")
                    }
                    Button {
                        isPDFPickerPresented = true
                    } label: {
                        Label("Import PDF…", systemImage: "doc.richtext")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
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
        .fileImporter(
            isPresented: $isPDFPickerPresented,
            allowedContentTypes: [.pdf]
        ) { result in
            handlePDFImport(result)
        }
        .task {
            store.send(.onAppear)
        }
    }

    /// Writes a plain-text string to the system clipboard. Cross-platform
    /// wrapper around `UIPasteboard` (iOS) and `NSPasteboard` (macOS).
    private func copyToClipboard(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    /// Handles the result of the SwiftUI `.fileImporter` PDF picker. The
    /// picked URL is security-scoped — we must start/stop access around the
    /// copy, and we copy to a plain temp file so the reducer can consume a
    /// URL with no lifetime restrictions.
    private func handlePDFImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                // Copy into a unique temp subdirectory so we can preserve
                // the picked file's original name. PDFIngestionClient uses
                // the URL's `lastPathComponent` as the title fallback — if
                // we named the scratch file `{uuid}.pdf` the resulting item
                // would show up in the library titled with a raw UUID.
                let scratchDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: scratchDir,
                    withIntermediateDirectories: true
                )
                let scratch = scratchDir.appendingPathComponent(pickedURL.lastPathComponent)
                try FileManager.default.copyItem(at: pickedURL, to: scratch)
                store.send(.importPDFSelected(scratch))
            } catch {
                store.send(.saveURLFailed("Couldn't read PDF: \(error.localizedDescription)"))
            }
        case .failure(let error):
            // User cancellation shows up here as NSError cancelled — treat
            // anything that isn't a real failure as a silent dismiss. The
            // fileImporter modifier does not distinguish cancel from error,
            // so we only surface errors that carry a message.
            let ns = error as NSError
            if ns.code != NSUserCancelledError {
                store.send(.saveURLFailed("PDF import failed: \(error.localizedDescription)"))
            }
        }
    }

    #if os(iOS)
    /// Modal URL-entry form shown when the user taps the toolbar "+".
    @ViewBuilder private var addURLSheet: some View {
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
                        Text(error).foregroundStyle(palette.error)
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
        case .all:
            return "All"
        case .unread:
            return "Unread"
        case .read:
            return "Read"
        case .starred:
            return "Starred"
        case .untagged:
            return "Untagged"
        case .recentlyDeleted:
            return "Recently Deleted"
        case let .tag(id):
            return store.availableTags.first { $0.id == id }?.name ?? "Tag"
        }
    }

    @ViewBuilder private var urlComposer: some View {
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
                // Liquid Glass input chip — the composer floats above the
                // library list as frosted glass, refracting whatever rows
                // sit behind it instead of the old flat 6% opacity fill.
                .glassEffect(.regular, in: .rect(cornerRadius: 6))
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
            .buttonStyle(.glassProminent)
            #endif

            Button {
                isPDFPickerPresented = true
            } label: {
                Label("Import PDF", systemImage: "doc.richtext")
            }
            .disabled(store.isSaving)
        }
    }

    /// The pill is purely for states the user might want to act on:
    /// extraction in progress, partial content, or outright failure.
    /// `.ready` and `.queued` are suppressed because they add no signal
    /// in the common case — every row in a healthy library is one or
    /// the other.
    private func shouldShowBadge(for state: ProcessingState) -> Bool {
        switch state {
        case .ready, .queued:
            return false
        case .extracting, .partial, .failed:
            return true
        }
    }

    private func processingBadge(_ state: ProcessingState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(badgeForeground(state))
            // Liquid Glass pill. The semantic state color becomes the
            // tint on the glass capsule so warning / error / extracting
            // still read at a glance over a scrolling list, while the
            // capsule itself refracts the row content behind it.
            .glassEffect(.regular.tint(badgeBackground(state)), in: .capsule)
    }

    private func badgeBackground(_ state: ProcessingState) -> Color {
        switch state {
        case .ready:
            return palette.success.opacity(0.16)
        case .partial:
            return palette.warning.opacity(0.16)
        case .failed:
            return palette.error.opacity(0.16)
        case .extracting:
            return palette.info.opacity(0.16)
        case .queued:
            return palette.tx3.opacity(0.16)
        }
    }

    private func badgeForeground(_ state: ProcessingState) -> Color {
        switch state {
        case .ready:
            return palette.success
        case .partial:
            return palette.warning
        case .failed:
            return palette.error
        case .extracting:
            return palette.info
        case .queued:
            return palette.tx2
        }
    }
}

// MARK: - Library Item Thumbnail

private struct LibraryItemThumbnail: View {
    let item: SavedItem

    private static let size: CGFloat = 72
    /// Max pixel dimension to downsample to. 4× the point size gives
    /// enough headroom for 3× Retina displays without wasting memory
    /// on unused resolution (the thumbnail cell is 72pt square).
    private static let targetPixelSize: CGFloat = size * 4

    var body: some View {
        Group {
            if let url = resolvedImageURL {
                CachedImageView(url: url, targetPixelSize: Self.targetPixelSize) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
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
                .accessibilityLabel("Document placeholder")
        }
    }

    private var resolvedImageURL: URL? {
        guard let heroURLString = item.heroImageURL, !heroURLString.isEmpty else {
            return nil
        }
        return URL(string: heroURLString)
    }
}
