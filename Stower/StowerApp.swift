import SwiftUI
import StowerFeature

@main
struct StowerApp: App {
    private let store = StowerAppBootstrap.makeStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
