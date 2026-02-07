import SwiftUI
@_exported import StowerFeature

public struct ContentView: View {
    private let store = StowerAppBootstrap.makeStore()

    public var body: some View {
        StowerFeature.ContentView(store: store)
    }

    public init() {}
}
