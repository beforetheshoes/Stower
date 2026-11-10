import ComposableArchitecture
import StowerFeature
import SwiftUI

@main
struct StowerApp: App {
    private let store = StowerAppBootstrap.makeStore()

    var body: some Scene {
        #if os(macOS)
        // One window. A second one would show the same store — the same
        // selection and the same open article — not a second view of the
        // library.
        Window("Stower", id: "main") {
            root
        }
        .commands {
            ReaderCommands(store: store)
        }
        // A save link from the Safari extension, or a file opened in Stower,
        // can arrive while the window is closed. This scene takes every
        // external event, so the window comes back to receive it.
        .handlesExternalEvents(matching: ["*"])

        Settings {
            SettingsWindow(store: store)
        }
        #else
        WindowGroup {
            root
        }
        .commands {
            ReaderCommands(store: store)
        }
        #endif
    }

    private var root: some View {
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
}
