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
        #if os(macOS)
        NavigationSplitView {
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
            } else {
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "doc.text",
                    description: Text("Choose an article from Library to read.")
                )
            }
        }
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
        #endif
    }
}
