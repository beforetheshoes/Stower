import ComposableArchitecture
import StowerData
import SwiftUI

public struct ContentView: View {
    let store: StoreOf<AppFeature>
    @Environment(\.scenePhase)
    private var scenePhase

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        AppView(store: store)
            .task { store.send(.onAppear) }
            .onChange(of: scenePhase) { _, newPhase in
                // When the user returns to Stower after sharing a URL from
                // Safari (or any other app), the share extension has already
                // enqueued an ingestion job to the shared App Group database,
                // but the main app has no other way to discover it. Re-drain
                // the queue and reload the library whenever the scene becomes
                // active. `AppFeature` guards against running before startup
                // has finished, so this is a safe no-op on the very first
                // activation after launch.
                if newPhase == .active {
                    store.send(.sceneDidBecomeActive)
                }
            }
    }
}

#if os(macOS)
public struct ReaderCommands: Commands {
    let store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some Commands {
        CommandMenu("Reader") {
            Button(store.isReaderFocused ? "Exit Reader Focus" : "Focus Reader") {
                store.send(.readerFocusButtonTapped)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!store.canFocusReader)

            Divider()

            Button("Previous Article") {
                store.send(.previousArticleButtonTapped)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!store.canNavigateToPreviousArticle)

            Button("Next Article") {
                store.send(.nextArticleButtonTapped)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!store.canNavigateToNextArticle)

            Divider()

            Button("Toggle Read") {
                store.send(.toggleSelectedItemRead)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!store.canFocusReader)

            Button("Toggle Star") {
                store.send(.toggleSelectedItemStarred)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!store.canFocusReader)
        }
    }
}
#endif

public struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previousColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var readerSession = ReaderWebSession()
    #if os(iOS)
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    @State private var isFilterSheetPresented = false
    #endif

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        let palette = store.palette

        navigationContainer(palette: palette)
            // No custom toolbar background — Liquid Glass renders the
            // window chrome automatically on iOS 26 / macOS 26. The
            // `.tint(palette.primary)` below is how Flexoki branding
            // still propagates into the glass bar.
            .tint(palette.primary)
            .preferredColorScheme(palette.colorScheme)
            .environment(\.flexokiPalette, palette)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let completedItem = store.recentlyCompletedItem {
                        completedItemNotice(completedItem, palette: palette)
                    }
                    if store.failedImportCount > 0 {
                        importFailureNotice(count: store.failedImportCount, palette: palette)
                    }
                }
            }
            .onChange(of: store.reader?.itemID) { _, itemID in
                if itemID == nil {
                    readerSession.reset()
                }
            }
            .alert($store.scope(state: \.resetAlert, action: \.resetAlert))
            .sheet(
                isPresented: Binding(
                    get: { store.isSettingsPresented },
                    set: { if !$0 { store.send(.closeSettings) } }
                )
            ) {
                NavigationStack {
                    SettingsScreen(store: store.scope(\.settings, action: \.settings))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { store.send(.closeSettings) }
                            }
                        }
                }
                .tint(palette.primary)
                .environment(\.flexokiPalette, palette)
                .preferredColorScheme(palette.colorScheme)
            }
    }

    private func importFailureNotice(
        count: Int,
        palette: FlexokiPalette
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(palette.warning)
                .accessibilityHidden(true)
            Text(count == 1 ? "1 import needs attention." : "\(count) imports need attention.")
                .font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Button("Dismiss") {
                store.send(.dismissFailedImportsTapped)
            }
            Button("Retry") {
                store.send(.retryFailedImportsTapped)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func completedItemNotice(
        _ item: SavedItem,
        palette: FlexokiPalette
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(palette.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Done")
                    .font(.callout)
                    .bold()
                Text(String(localized: "Still saved in Library"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") {
                store.send(.undoCompletedItemTapped)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Done. \(item.title) is still saved in Library.")
        .accessibilityAction(named: "Undo") {
            store.send(.undoCompletedItemTapped)
        }
    }

    @ViewBuilder
    private func navigationContainer(palette: FlexokiPalette) -> some View {
        #if os(macOS)
        if store.isReaderFocused,
           let readerStore = store.scope(\.reader, action: \.reader.presented) {
            readerSurface(
                readerStore,
                palette: palette,
                isFocused: true
            )
        } else {
            splitNavigationView(palette: palette)
        }
        #else
        #if os(iOS)
        // On iPhone (compact), NavigationSplitView's detail column does not
        // reliably push when an `if let` swap toggles its content — taps on
        // library rows mutate `state.reader` but the screen never advances.
        // Use a single NavigationStack with the library as the root and the
        // reader as a binding-driven `.navigationDestination`, which pushes
        // and pops correctly and auto-clears `state.reader` on pop.
        if horizontalSizeClass == .compact {
            NavigationStack {
                LibraryScreen(
                    store: store.scope(\.library, action: \.library),
                    onOpenSettings: nil
                ) { isFilterSheetPresented = true }
                    .scrollContentBackground(.hidden)
                    .background(palette.bg)
                    .navigationDestination(
                        item: $store.scope(\.$reader, action: \.reader)
                    ) { readerStore in
                        ReaderScreen(store: readerStore)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(palette.bg)
                    }
            }
            .sheet(isPresented: $isFilterSheetPresented) {
                filterSheet(palette: palette)
            }
        } else {
            splitNavigationView(palette: palette)
        }
        #else
        splitNavigationView(palette: palette)
        #endif
        #endif
    }

    #if os(iOS)
    /// Modal sidebar presented from the iPhone library toolbar. Reuses the
    /// shared `SidebarScreen`, but rows are wired to dismiss the sheet via
    /// the `onSelect` closure rather than push a NavigationSplitView column.
    @ViewBuilder
    private func filterSheet(palette: FlexokiPalette) -> some View {
        NavigationStack {
            SidebarScreen(
                store: store.scope(\.sidebar, action: \.sidebar),
                onOpenSettings: {
                    isFilterSheetPresented = false
                    store.send(.openSettings)
                },
                onSelect: { _ in
                    isFilterSheetPresented = false
                }
            )
            .scrollContentBackground(.hidden)
            .background(palette.bg2)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isFilterSheetPresented = false }
                }
            }
        }
        .tint(palette.primary)
        .environment(\.flexokiPalette, palette)
        .preferredColorScheme(palette.colorScheme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

    @ViewBuilder
    private func splitNavigationView(palette: FlexokiPalette) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarScreen(
                store: store.scope(\.sidebar, action: \.sidebar)
            ) {
                store.send(.openSettings)
            }
            .scrollContentBackground(.hidden)
            .background(palette.bg2)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            LibraryScreen(store: store.scope(\.library, action: \.library))
                .scrollContentBackground(.hidden)
                .background(palette.bg2)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 500)
        } detail: {
            // `ContentUnavailableView` is self-sizing, so `.background()`
            // alone only paints the card-sized area around its content —
            // leaving the rest of the detail column painted in the system
            // `windowBackgroundColor` (white in light mode). We have to
            // explicitly expand the content to fill the column *before*
            // applying the background so the fill paints the entire pane.
            #if os(macOS)
            if let readerStore = store.scope(\.reader, action: \.reader.presented) {
                readerSurface(
                    readerStore,
                    palette: palette,
                    isFocused: false
                )
            } else {
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "doc.text",
                    description: Text("Choose an article from Library to read.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bg)
            }
            #else
            if let readerStore = store.scope(\.reader, action: \.reader.presented) {
                NavigationStack {
                    ReaderScreen(
                        store: readerStore,
                        session: readerSession,
                        isReaderFocused: store.isReaderFocused
                    ) { store.send(.readerFocusButtonTapped) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bg)
            } else {
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "doc.text",
                    description: Text("Choose an article from Library to read.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bg)
            }
            #endif
        }
        #if os(iOS)
        .onChange(of: store.isReaderFocused) { _, isFocused in
            if isFocused {
                previousColumnVisibility = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = previousColumnVisibility
            }
        }
        #endif
    }

    #if os(macOS)
    private func readerSurface(
        _ readerStore: StoreOf<ReaderFeature>,
        palette: FlexokiPalette,
        isFocused: Bool
    ) -> some View {
        NavigationStack {
            ReaderScreen(
                store: readerStore,
                session: readerSession,
                isReaderFocused: isFocused
            ) { store.send(.readerFocusButtonTapped) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
    }
    #endif
}
