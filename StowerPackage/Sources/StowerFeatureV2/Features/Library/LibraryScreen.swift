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
    var palette
    @Environment(\.openURL)
    var openURL
    /// Invoked when the user taps the settings gear in the iOS toolbar.
    /// nil on macOS (the sidebar already has its own settings button).
    let onOpenSettings: (() -> Void)?
    /// Invoked when the user taps the filter button in the iOS toolbar.
    /// nil on macOS / iPad split-view where the sidebar column is always
    /// visible. Set on iPhone compact to surface the filter sheet.
    let onOpenFilters: (() -> Void)?
    /// True in the split layout (Mac, regular-width iPad), where the open
    /// article is a list selection with a highlight and keyboard navigation.
    /// False on iPhone, where rows push the reader.
    let usesSelection: Bool
    #if os(iOS)
    @FocusState var isURLFieldFocused: Bool
    #endif

    public init(
        store: StoreOf<LibraryFeature>,
        usesSelection: Bool = false,
        onOpenSettings: (() -> Void)? = nil,
        onOpenFilters: (() -> Void)? = nil
    ) {
        self.store = store
        self.usesSelection = usesSelection
        self.onOpenSettings = onOpenSettings
        self.onOpenFilters = onOpenFilters
    }

    var selection: Binding<UUID?>? {
        guard usesSelection else { return nil }
        return Binding(
            get: { store.openItemID },
            set: { store.send(.rowSelected($0)) }
        )
    }

    public var body: some View {
        List(selection: selection) {
            #if os(macOS)
            // On macOS the inline composer lives at the top of the list
            // because the window is wide enough that it doesn't crowd the
            // article rows. iOS moves it into a sheet triggered by the
            // toolbar "+" button so the list is clean.
            Section {
                urlComposer
                    .listRowBackground(Color.clear)
                if store.saveState == .failed, let error = store.errorMessage {
                    CopyableText(text: error, textColor: palette.error)
                        .listRowBackground(Color.clear)
                }
            }
            if let error = store.errorMessage, store.saveState != .failed {
                CopyableText(text: error, font: .body, textColor: palette.error)
                    .listRowBackground(Color.clear)
            }
            #else
            // The composer is a sheet on iOS, so a failure that arrives
            // while it is closed — a file import, an "Open in Stower" — had
            // nowhere to appear.
            if let error = store.errorMessage, !store.isAddURLPresented {
                CopyableText(text: error, font: .body, textColor: palette.error)
                    .listRowBackground(Color.clear)
            }
            #endif

            ForEach(store.items) { item in
                libraryRow(item)
                .tag(item.id)
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
                            store.send(.permanentlyDeleteTapped(item.id))
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
                            ClipboardSupport.copy(sourceURLString)
                        }
                    }
                    if store.filter == .recentlyDeleted {
                        Button("Restore") {
                            store.send(.restoreFromTrash(item.id))
                        }
                        Button("Delete Forever", role: .destructive) {
                            store.send(.permanentlyDeleteTapped(item.id))
                        }
                    } else {
                        Button(item.isStarred ? "Unstar" : "Star") {
                            store.send(.toggleStar(item.id))
                        }
                        Button(item.isRead ? "Mark as Unread" : "Mark as Read") {
                            store.send(.toggleRead(item.id))
                        }
                        tagsSubmenu(for: item)
                        downloadManagementMenuItems(for: item)
                        Button("Refresh Reader View") {
                            store.send(.reprocessItem(item.id))
                        }
                        if item.isEPUBExportable, store.storageInfoByID[item.id]?.offloadedAt == nil {
                            Button("Export as EPUB…") {
                                store.send(.exportEPUBTapped(item.id))
                            }
                            .disabled(store.exportingItemID != nil)
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
        .confirmationDialog($store.scope(state: \.deleteConfirmation, action: \.deleteConfirmation))
        .overlay {
            // Only after the first observation has delivered: a populated
            // list must never be covered by a spinner, and the empty state
            // must not flash before the rows arrive.
            if store.hasLoaded, store.items.isEmpty {
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
                        presentEPUBImporter()
                    } label: {
                        Label("Import EPUB…", systemImage: "book")
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
        // The reducer closes this the moment the link is queued; the fetch
        // continues in the background and the row arrives on its own.
        .sheet(isPresented: $store.isAddURLPresented.sending(\.addURLPresentationChanged)) {
            addURLSheet
        }
        #else
        // Sort and layout were only reachable on iOS.
        .toolbar {
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
        }
        #endif
        .sheet(isPresented: $store.showsTextImportSheet.sending(\.textImportPresentationChanged)) {
            textImportSheet
        }
        #if os(iOS)
        .sheet(item: $store.importPicker.sending(\.importPickerChanged)) { picker in
            IOSDocumentPicker(
                allowedContentTypes: contentTypes(for: picker)
            ) { result in
                store.send(.importPickerChanged(nil))
                switch picker {
                case .text:
                    handleTextImport(result)
                case .pdf:
                    handlePDFImport(result)
                case .epub:
                    handleEPUBImport(result)
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

    /// A selectable row in the split layout, a push button on iPhone.
    @ViewBuilder
    func libraryRow(_ item: SavedItem) -> some View {
        let row = LibraryItemRow(
            item: item,
            query: store.query,
            tags: resolvedTags(for: item),
            displayStyle: store.displayStyle,
            isOffloaded: store.storageInfoByID[item.id]?.offloadedAt != nil
        )
        if usesSelection {
            row
        } else {
            Button {
                store.send(.openItem(item))
            } label: {
                row
            }
            .buttonStyle(.plain)
        }
    }
}
