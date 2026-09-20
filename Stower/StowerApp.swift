import ComposableArchitecture
import StowerFeature
import SwiftUI

@main
struct StowerApp: App {
    private let store = StowerAppBootstrap.makeStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onOpenURL { incomingURL in
                    // "Open in Stower" from Files, Finder, Mail and the like.
                    if incomingURL.isFileURL {
                        store.send(.fileOpened(incomingURL))
                        return
                    }
                    guard case let .save(url) = BrowserExtensionLink(incomingURL) else { return }
                    store.send(.browserExtensionURLReceived(url))
                }
        }
        #if os(macOS)
        .commands {
            ReaderCommands(store: store)
        }
        #endif
    }
}
