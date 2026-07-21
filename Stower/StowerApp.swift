import ComposableArchitecture
import StowerFeature
import SwiftUI

@main
struct StowerApp: App {
    private let store = StowerAppBootstrap.makeStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        #if os(macOS)
        .commands {
            ReaderCommands(store: store)
        }
        #endif
    }
}
