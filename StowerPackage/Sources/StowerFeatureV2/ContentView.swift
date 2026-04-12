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

public struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
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
            .alert($store.scope(state: \.resetAlert, action: \.resetAlert))
            .sheet(
                isPresented: Binding(
                    get: { store.isSettingsPresented },
                    set: { if !$0 { store.send(.closeSettings) } }
                )
            ) {
                NavigationStack {
                    SettingsScreen(store: store.scope(state: \.settings, action: \.settings))
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

    @ViewBuilder
    private func navigationContainer(palette: FlexokiPalette) -> some View {
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
                    store: store.scope(state: \.library, action: \.library)
                ) {
                    isFilterSheetPresented = true
                }
                    .scrollContentBackground(.hidden)
                    .background(palette.bg)
                    .navigationDestination(
                        item: $store.scope(state: \.reader, action: \.reader)
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
    }

    #if os(iOS)
    /// Modal sidebar presented from the iPhone library toolbar. Reuses the
    /// shared `SidebarScreen`, but rows are wired to dismiss the sheet via
    /// the `onSelect` closure rather than push a NavigationSplitView column.
    @ViewBuilder
    private func filterSheet(palette: FlexokiPalette) -> some View {
        NavigationStack {
            SidebarScreen(
                store: store.scope(state: \.sidebar, action: \.sidebar),
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
                store: store.scope(state: \.sidebar, action: \.sidebar)
            ) {
                store.send(.openSettings)
            }
            .scrollContentBackground(.hidden)
            .background(palette.bg2)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            LibraryScreen(store: store.scope(state: \.library, action: \.library))
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
            if let readerStore = store.scope(state: \.reader, action: \.reader.presented) {
                NavigationStack {
                    ReaderScreen(store: readerStore)
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
        }
    }
}
