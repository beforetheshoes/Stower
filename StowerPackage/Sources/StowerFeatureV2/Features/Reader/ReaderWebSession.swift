import Foundation
import Observation
import WebKit

/// Owns the live reader resources independently of transient SwiftUI updates.
/// During the macOS focus transition the reader view explicitly detaches and
/// reattaches, while this session keeps its page, archive server, restoration,
/// and panel state stable.
@MainActor
@Observable
public final class ReaderWebSession {
    struct LoadKey: Hashable {
        let contentVersion: Int
        let itemID: UUID
    }

    var archiveServer: LocalArchiveServer?
    var hasRestoredPosition = false
    var isAIPanelPresented = false
    var isAppearancePanelPresented = false
    var isFindNavigatorPresented = false
    var isListenPanelPresented = false
    var isPDFViewerPresented = false
    var loadKey: LoadKey?
    var page: WebPage?

    public init() {}

    func beginLoading(_ key: LoadKey) {
        ReaderProgressCoordinator.shared.register(nil)
        archiveServer?.stop()
        archiveServer = nil
        hasRestoredPosition = false
        loadKey = key
        page = nil
    }

    func reset() {
        ReaderProgressCoordinator.shared.register(nil)
        archiveServer?.stop()
        archiveServer = nil
        hasRestoredPosition = false
        loadKey = nil
        page = nil
        isAIPanelPresented = false
        isAppearancePanelPresented = false
        isFindNavigatorPresented = false
        isListenPanelPresented = false
        isPDFViewerPresented = false
    }
}
