import ComposableArchitecture
import SwiftUI

public struct ContentView: View {
    let store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        AppView(store: store)
            .task { store.send(.onAppear) }
    }
}

public struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        let theme = store.readerTheme

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarScreen(
                store: store.scope(state: \.sidebar, action: \.sidebar),
                onOpenSettings: { store.send(.openSettings) }
            )
            .scrollContentBackground(.hidden)
            .background(theme.sidebarBackground)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            LibraryScreen(store: store.scope(state: \.library, action: \.library))
                .scrollContentBackground(.hidden)
                .background(theme.sidebarBackground)
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
                .background(theme.readerBackground)
            } else {
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "doc.text",
                    description: Text("Choose an article from Library to read.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.readerBackground)
            }
        }
        #if os(macOS)
        .toolbarBackground(theme.toolbarBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #else
        .toolbarBackground(theme.toolbarBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .preferredColorScheme(theme.colorScheme)
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
        }
    }
}

private extension ReaderTheme {
    var colorScheme: ColorScheme {
        switch self {
        case .white, .sepia: return .light
        case .dark: return .dark
        }
    }

    var readerBackground: Color {
        switch self {
        case .white:
            return .white
        case .sepia:
            return Color(red: 0.96, green: 0.92, blue: 0.84)
        case .dark:
            return Color(red: 0.09, green: 0.10, blue: 0.12)
        }
    }

    var sidebarBackground: Color {
        switch self {
        case .white:
            return Color(red: 0.97, green: 0.97, blue: 0.99)
        case .sepia:
            return Color(red: 0.93, green: 0.88, blue: 0.80)
        case .dark:
            return Color(red: 0.13, green: 0.14, blue: 0.16)
        }
    }

    var toolbarBackground: Color {
        switch self {
        case .white:
            return Color(red: 0.95, green: 0.95, blue: 0.97)
        case .sepia:
            return Color(red: 0.91, green: 0.86, blue: 0.77)
        case .dark:
            return Color(red: 0.16, green: 0.17, blue: 0.20)
        }
    }
}
