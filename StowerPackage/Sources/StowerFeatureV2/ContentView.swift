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

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        let theme = store.readerTheme
        #if os(macOS)
        NavigationSplitView {
            Group {
                switch store.selectedSection {
                case .library:
                    LibraryScreen(store: store.scope(state: \.library, action: \.library))
                case .settings:
                    SettingsScreen(store: store.scope(state: \.settings, action: \.settings))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Picker("", selection: $store.selectedSection.sending(\.selectedSectionChanged)) {
                    Label("Library", systemImage: "books.vertical")
                        .tag(AppFeature.State.Section.library)
                    Label("Settings", systemImage: "gear")
                        .tag(AppFeature.State.Section.settings)
                }
                .pickerStyle(.segmented)
                .padding(12)
                .background(theme.sidebarBackground)
            }
            .scrollContentBackground(.hidden)
            .background(theme.sidebarBackground)
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 500)
        } detail: {
            if let readerStore = store.scope(state: \.reader, action: \.reader.presented) {
                NavigationStack {
                    ReaderScreen(store: readerStore)
                        .toolbar {
                            ToolbarItem(placement: .automatic) {
                                Button("Close") {
                                    store.send(.closeReaderTapped)
                                }
                            }
                        }
                }
                .background(theme.readerBackground)
            } else {
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "doc.text",
                    description: Text("Choose an article from Library to read.")
                )
                .background(theme.readerBackground)
            }
        }
        .toolbarBackground(theme.toolbarBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .preferredColorScheme(theme.colorScheme)
        .alert($store.scope(state: \.resetAlert, action: \.resetAlert))
        #else
        NavigationStack {
            TabView(selection: $store.selectedSection.sending(\.selectedSectionChanged)) {
                LibraryScreen(store: store.scope(state: \.library, action: \.library))
                    .tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .tag(AppFeature.State.Section.library)

                SettingsScreen(store: store.scope(state: \.settings, action: \.settings))
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(AppFeature.State.Section.settings)
            }
            .sheet(item: $store.scope(state: \.reader, action: \.reader)) { readerStore in
                NavigationStack { ReaderScreen(store: readerStore) }
            }
        }
        .toolbarBackground(theme.toolbarBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(theme.colorScheme)
        .alert($store.scope(state: \.resetAlert, action: \.resetAlert))
        #endif
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
