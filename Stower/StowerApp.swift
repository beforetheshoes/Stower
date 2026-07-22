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
