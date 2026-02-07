import SwiftUI
import StowerFeature

@main
struct StowerMacApp: App {
    private let store = StowerAppBootstrap.makeStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .defaultSize(width: 1200, height: 800)
    }
}
