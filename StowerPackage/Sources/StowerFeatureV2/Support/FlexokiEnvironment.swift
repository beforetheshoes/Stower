import SwiftUI

/// SwiftUI environment key so any view can read the current Flexoki palette
/// without having to thread the reader appearance settings through every
/// intermediate reducer/binding. The root `AppView` sets this once from the
/// AppFeature store; every descendant reads it via
/// `@Environment(\.flexokiPalette)`.
private struct FlexokiPaletteKey: EnvironmentKey {
    static let defaultValue: FlexokiPalette = .default
}

extension EnvironmentValues {
    public var flexokiPalette: FlexokiPalette {
        get { self[FlexokiPaletteKey.self] }
        set { self[FlexokiPaletteKey.self] = newValue }
    }
}
