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
    @State private var isTextImportPresented = false
    #if os(iOS)
    @State private var activeImportPicker: IOSImportPicker?
    #endif

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
                    LibraryItemRow(
                        item: item,
                        query: store.query,
                        tags: resolvedTags(for: item),
                        displayStyle: store.displayStyle
                    )
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
                            Label("Refresh Reader View", systemImage: "arrow.clockwise")
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
                        Button("Refresh Reader View") {
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
        // Obscure rows as they scroll beneath the Liquid Glass nav bar so
        // the first row stays legible against the glass material.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(navigationTitle)
        .searchable(text: $store.query.sending(\.queryChanged), prompt: "Search")
        .overlay {
            if store.isLoading {
                ProgressView()
            } else if store.filteredItems.isEmpty {
                libraryEmptyState
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
                Menu("View Options", systemImage: "rectangle.grid.1x2") {
                    Picker(
                        "Layout",
                        selection: $store.displayStyle.sending(\.displayStyleChanged)
                    ) {
                        ForEach(LibraryDisplayStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Picker(
                        "Sort",
                        selection: $store.sortOrder.sending(\.sortOrderChanged)
                    ) {
                        ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        presentAddURLSheet()
                    } label: {
                        Label("Add URL…", systemImage: "link")
                    }
                    Button {
                        presentTextImportSheet()
                    } label: {
                        Label("Add Text/Markdown…", systemImage: "square.and.pencil")
                    }
                    Button {
                        presentTextFileImporter()
                    } label: {
                        Label("Import Text/Markdown…", systemImage: "doc.text")
                    }
                    Button {
                        presentPDFImporter()
                    } label: {
                        Label("Import PDF…", systemImage: "doc.richtext")
                    }
                    Button {
                        presentWebsiteImporter()
                    } label: {
                        Label("Import Website Archive…", systemImage: "globe")
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
        .sheet(
            isPresented: Binding(
                get: { isTextImportPresented && store.textImportDraft != nil },
                set: {
                    isTextImportPresented = $0
                    if !$0 {
                        store.send(.textImportDismissed)
                    }
                }
            )
        ) {
            textImportSheet
        }
        .onChange(of: store.saveState) { _, newValue in
            if isTextImportPresented, newValue == .ready, store.textImportDraft == nil {
                isTextImportPresented = false
            }
        }
        #if os(iOS)
        .sheet(item: $activeImportPicker) { picker in
            IOSDocumentPicker(
                allowedContentTypes: contentTypes(for: picker)
            ) { result in
                activeImportPicker = nil
                switch picker {
                case .text:
                    handleTextImport(result)
                case .pdf:
                    handlePDFImport(result)
                case .website:
                    handleWebsiteImport(result)
                }
            }
        }
        #endif
        .sheet(isPresented: Binding(
            get: { store.inlineTagCreation != nil },
            set: { if !$0 { store.send(.inlineCreateTagDismissed) } }
        )) {
            NewTagSheet(
                name: Binding(
                    get: { store.inlineTagCreation?.name ?? "" },
                    set: { store.send(.inlineCreateTagNameChanged($0)) }
                ),
                colorHex: Binding(
                    get: { store.inlineTagCreation?.colorHex ?? "" },
                    set: { store.send(.inlineCreateTagColorChanged($0)) }
                ),
                palette: palette,
                onCancel: { store.send(.inlineCreateTagDismissed) },
                onCreate: { store.send(.inlineCreateTagConfirmed) }
            )
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

    private func presentAddURLSheet() {
        if store.saveState == .failed {
            store.send(.sourceURLChanged(""))
        }
        DispatchQueue.main.async {
            isAddURLPresented = true
        }
    }

    private func presentTextImportSheet() {
        store.send(.addTextTapped)
        DispatchQueue.main.async {
            isTextImportPresented = true
        }
    }

    private func presentTextFileImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: textImportContentTypes,
            title: "Import Text or Markdown"
        ) { url in
            handleTextImport(.success(url))
        }
        #else
        DispatchQueue.main.async {
            activeImportPicker = .text
        }
        #endif
    }

    private func presentPDFImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.pdf],
            title: "Import PDF"
        ) { url in
            handlePDFImport(.success(url))
        }
        #else
        DispatchQueue.main.async {
            activeImportPicker = .pdf
        }
        #endif
    }

    private func presentWebsiteImporter() {
        #if os(macOS)
        presentOpenPanel(
            allowedContentTypes: [.zip],
            title: "Import Website Archive"
        ) { url in
            handleWebsiteImport(.success(url))
        }
        #else
        DispatchQueue.main.async {
            activeImportPicker = .website
        }
        #endif
    }

    #if os(macOS)
    private func presentOpenPanel(
        allowedContentTypes: [UTType],
        title: String,
        onSelect: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onSelect(url)
        }
    }
    #endif

    private var textImportContentTypes: [UTType] {
        let markdownTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
        return [.plainText] + markdownTypes
    }

    /// Handles the result of the SwiftUI `.fileImporter` PDF picker. The
    /// picked URL is security-scoped — we must start/stop access around the
    /// copy, and we copy to a plain temp file so the reducer can consume a
    /// URL with no lifetime restrictions.
    /// Handles the result of a `.zip` website archive picker. Uses the same
    /// security-scoped + scratch-copy dance as `handlePDFImport` so the
    /// reducer consumes a plain temp URL with no lifetime restrictions.
    private func handleWebsiteImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let scratchDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: scratchDir,
                    withIntermediateDirectories: true
                )
                let scratch = scratchDir.appendingPathComponent(pickedURL.lastPathComponent)
                try FileManager.default.copyItem(at: pickedURL, to: scratch)
                store.send(.importWebsiteSelected(scratch))
            } catch {
                store.send(.saveURLFailed("Couldn't read zip: \(error.localizedDescription)"))
            }
        case .failure(let error):
            let ns = error as NSError
            if ns.code != NSUserCancelledError {
                store.send(.saveURLFailed("Website import failed: \(error.localizedDescription)"))
            }
        }
    }

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

    private func handleTextImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            guard let mode = TextImportDetector.importMode(for: pickedURL) else {
                store.send(.saveURLFailed("Unsupported text file type."))
                return
            }
            do {
                let data = try Data(contentsOf: pickedURL)
                let text = decodedImportedText(from: data)
                let titleHint = TextImportDetector.normalizedTitleHint(from: pickedURL)
                store.send(.importTextResolved(text, titleHint, mode))
            } catch {
                store.send(.saveURLFailed("Couldn't read text file: \(error.localizedDescription)"))
            }
        case .failure(let error):
            let ns = error as NSError
            if ns.code != NSUserCancelledError {
                store.send(.saveURLFailed("Text import failed: \(error.localizedDescription)"))
            }
        }
    }

    #if os(iOS)
    private enum IOSImportPicker: String, Identifiable {
        case text = "text"
        case pdf = "pdf"
        case website = "website"

        var id: String { rawValue }
    }

    private func contentTypes(for picker: IOSImportPicker) -> [UTType] {
        switch picker {
        case .text:
            return textImportContentTypes
        case .pdf:
            return [.pdf]
        case .website:
            return [.zip]
        }
    }

    private struct IOSDocumentPicker: UIViewControllerRepresentable {
        let allowedContentTypes: [UTType]
        let onComplete: (Result<URL, Error>) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onComplete: onComplete)
        }

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let controller = UIDocumentPickerViewController(
                forOpeningContentTypes: allowedContentTypes,
                asCopy: false
            )
            controller.delegate = context.coordinator
            controller.allowsMultipleSelection = false
            return controller
        }

        func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

        final class Coordinator: NSObject, UIDocumentPickerDelegate {
            private let onComplete: (Result<URL, Error>) -> Void

            init(onComplete: @escaping (Result<URL, Error>) -> Void) {
                self.onComplete = onComplete
            }

            func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                guard let url = urls.first else {
                    onComplete(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
                    return
                }
                onComplete(.success(url))
            }

            func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
                onComplete(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
            }
        }
    }

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

    @ViewBuilder private var textImportSheet: some View {
        TextAuthoringSheet(
            title: Binding(
                get: { store.textImportDraft?.title ?? "" },
                set: { store.send(.textImportTitleChanged($0)) }
            ),
            text: Binding(
                get: { store.textImportDraft?.text ?? "" },
                set: { store.send(.textImportTextChanged($0)) }
            ),
            mode: Binding(
                get: { store.textImportDraft?.mode ?? .auto },
                set: { store.send(.textImportModeChanged($0)) }
            ),
            palette: palette,
            errorMessage: store.saveState == .failed ? store.errorMessage : nil,
            isSaving: store.isSaving,
            navigationTitle: "Add Text",
            onCancel: {
                isTextImportPresented = false
                store.send(.textImportDismissed)
            },
            onSave: {
                store.send(.saveTextImportTapped)
            }
        )
    }

    private func decodedImportedText(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - Tag Pills

    @ViewBuilder
    private func tagPillsRow(for item: SavedItem) -> some View {
        let tags = resolvedTags(for: item)
        if !tags.isEmpty {
            let visible = Array(tags.prefix(3))
            let overflow = tags.count - visible.count
            HStack(spacing: 4) {
                ForEach(visible) { tag in
                    let color = tagPillColor(tag.colorHex)
                    Text(tag.name)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(color)
                        .background(color.opacity(0.15), in: .capsule)
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption2)
                        .foregroundStyle(palette.tx2)
                }
            }
        }
    }

    private func resolvedTags(for item: SavedItem) -> [Tag] {
        item.tagIDs.compactMap { id in
            store.availableTags.first { $0.id == id }
        }
    }

    @ViewBuilder private var libraryEmptyState: some View {
        if !store.query.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try another title, publication, tag, or phrase from the article.")
            )
        } else {
            switch store.filter {
            case .unread:
                ContentUnavailableView {
                    Label("Inbox Zero", systemImage: "checkmark.circle")
                } description: {
                    Text("Nothing is waiting to be read. Completed articles stay available in Library, Starred, and Tags.")
                } actions: {
                    #if os(iOS)
                    Button("Add a Link", systemImage: "link", action: presentAddURLSheet)
                        .buttonStyle(.borderedProminent)
                    #endif
                }
            case .all:
                ContentUnavailableView {
                    Label(String(localized: "Your Library Is Empty"), systemImage: "books.vertical")
                } description: {
                    Text("Save an article or website to keep it here for reading and future reference.")
                } actions: {
                    #if os(iOS)
                    Button("Add a Link", systemImage: "link", action: presentAddURLSheet)
                        .buttonStyle(.borderedProminent)
                    #endif
                }
            default:
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: "tray",
                    description: Text("Articles that match this list will appear here.")
                )
            }
        }
    }

    private func tagPillColor(_ hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return palette.secondary }
        return Color(hex: hex)
    }

    @ViewBuilder
    private func libraryProgressRow(_ progress: ReadingProgressSnapshot) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 0)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.ui.opacity(0.28))
                    Capsule()
                        .fill(palette.primaryMuted)
                        .frame(width: width * progress.fractionComplete)
                }
            }
            .frame(height: 4)

            Text("\(progress.percentComplete)%")
                .font(.caption2.weight(.medium))
                .foregroundStyle(palette.tx2)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tags Submenu

    @ViewBuilder
    private func tagsSubmenu(for item: SavedItem) -> some View {
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
            Divider()
            Button {
                store.send(.inlineCreateTagTapped(item.id))
            } label: {
                Label("New Tag\u{2026}", systemImage: "plus")
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
    }

    private var navigationTitle: String {
        switch store.filter {
        case .all:
            return "Library"
        case .unread:
            return "Inbox"
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
            TextField("Paste article URL", text: $store.sourceURL.sending(\.sourceURLChanged))
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
                // sit beneath it instead of the old flat 6% opacity fill.
                .glassEffect(.regular, in: .rect(cornerRadius: 6))
                .onSubmit { store.send(.saveURLTapped) }

            #if os(macOS)
            Button {
                store.send(store.isSaving ? .cancelURLSaveTapped : .saveURLTapped)
            } label: {
                if store.isSaving {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                } else {
                    Label("Add", systemImage: "plus.circle.fill")
                }
            }
            .buttonStyle(.glassProminent)
            .fixedSize()

            Menu {
                Section("Text") {
                    Button {
                        presentTextImportSheet()
                    } label: {
                        Label("Write or Paste Text…", systemImage: "square.and.pencil")
                    }
                }

                Section("Import") {
                    Button {
                        presentTextFileImporter()
                    } label: {
                        Label("Import Text/Markdown…", systemImage: "doc.text")
                    }

                    Button {
                        presentPDFImporter()
                    } label: {
                        Label("Import PDF…", systemImage: "doc.richtext")
                    }

                    Button {
                        presentWebsiteImporter()
                    } label: {
                        Label("Import Website Archive…", systemImage: "globe")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            .disabled(store.isSaving)
            #else
            Button {
                store.send(store.isSaving ? .cancelURLSaveTapped : .saveURLTapped)
            } label: {
                if store.isSaving {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                } else {
                    Label("Add URL", systemImage: "plus.circle.fill")
                }
            }
            #endif
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
            // capsule itself refracts the row content beneath it.
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
        // `stower-archive:<relative-path>` is produced by the website-archive
        // importer: each device resolves it against its own local archive
        // directory so the field can sync cross-device without pinning a
        // file URL. Fall through to regular URL parsing for every other
        // scheme (http/https/data/etc.).
        let scheme = WebsiteArchiveUnpacker.heroArchiveURLScheme + ":"
        if heroURLString.hasPrefix(scheme) {
            let relative = String(heroURLString.dropFirst(scheme.count))
            guard !relative.isEmpty else { return nil }
            let fileURL = AssetArchiver.archiveDirectory(for: item.id)
                .appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            return fileURL
        }
        return URL(string: heroURLString)
    }
}
