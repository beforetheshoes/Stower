import Observation

/// Owns reader controls that should remain stable across transient SwiftUI updates.
///
/// The live `WebPage` deliberately does not live here. A `WebPage` can be bound
/// to only one native `WebView`, while a shared reader session can briefly be
/// observed by more than one SwiftUI view during navigation transitions.
@MainActor
@Observable
public final class ReaderWebSession {
    var isAIPanelPresented = false
    var isAppearancePanelPresented = false
    var isFindNavigatorPresented = false
    var isListenPanelPresented = false
    var isPDFViewerPresented = false

    public init() {}

    func reset() {
        isAIPanelPresented = false
        isAppearancePanelPresented = false
        isFindNavigatorPresented = false
        isListenPanelPresented = false
        isPDFViewerPresented = false
    }
}
