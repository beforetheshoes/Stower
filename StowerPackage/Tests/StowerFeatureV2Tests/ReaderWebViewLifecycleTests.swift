#if os(macOS)
import AppKit
import ComposableArchitecture
import StowerData
@testable import StowerFeature
import SwiftUI
import Testing
import WebKit

@MainActor
struct ReaderWebViewLifecycleTests {
    @Test("Transient reader overlap gives each native WebView its own WebPage")
    func transientReaderOverlapDoesNotShareWebPage() async throws {
        let store = makeReaderStore()
        let hostingView = NSHostingView(rootView: ReaderOverlapHarness(store: store))
        let window = makeWindow(contentView: hostingView)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let webViews = await waitForWebViews(count: 2, in: hostingView)
        #expect(
            webViews.count == 2,
            "Each temporarily overlapping reader must mount an independently owned WebView."
        )
    }

    @Test("Focus mode replaces the split view with a reader-only layout")
    func focusTransitionUsesReaderOnlyLayout() async throws {
        let store = makeAppStore()
        let hostingView = NSHostingView(rootView: AppView(store: store))
        let window = makeWindow(contentView: hostingView)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let initialWebView = await waitForWebView(in: hostingView)
        #expect(initialWebView != nil, "The test must mount the native WebView before changing focus.")
        #expect(
            descendants(of: NSSplitView.self, in: hostingView).isEmpty == false,
            "The ordinary reader layout must begin inside the navigation split view."
        )

        for transitionNumber in 1 ... 2 {
            store.send(.readerFocusButtonTapped)
            let didEnterReaderOnlyLayout = await waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return descendants(of: NSSplitView.self, in: hostingView).isEmpty
                    && descendants(of: WKWebView.self, in: hostingView).count == 1
            }
            #expect(
                didEnterReaderOnlyLayout,
                "Focus transition \(transitionNumber) must remove the sidebar and library split view while keeping one reader alive."
            )

            store.send(.readerFocusButtonTapped)
            let didRestoreSplitLayout = await waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return descendants(of: NSSplitView.self, in: hostingView).isEmpty == false
                    && descendants(of: WKWebView.self, in: hostingView).count == 1
            }
            #expect(
                didRestoreSplitLayout,
                "Exit transition \(transitionNumber) must restore the split view while keeping one reader alive."
            )
        }
    }

    private func makeReaderStore() -> StoreOf<ReaderFeature> {
        let item = SavedItem(
            title: "Reader lifecycle test",
            content: "Reader lifecycle test",
            renderFormat: .structuredV1
        )
        var state = ReaderFeature.State(item: item)
        state.document = ReaderDocument(
            title: item.title,
            blocks: [.paragraph([.text("Reader lifecycle test")])]
        )
        return Store(initialState: state) {
            ReaderFeature()
        }
    }

    private func makeAppStore() -> StoreOf<AppFeature> {
        let item = SavedItem(
            title: "Reader focus test",
            content: "Reader focus test",
            renderFormat: .structuredV1
        )
        var state = AppFeature.State()
        var reader = ReaderFeature.State(item: item, appearance: state.cachedAppearance)
        reader.document = ReaderDocument(
            title: item.title,
            blocks: [.paragraph([.text("Reader focus test")])]
        )
        state.reader = reader
        return Store(initialState: state) {
            AppFeature()
        }
    }

    private func makeWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func waitForWebView(in rootView: NSView) async -> WKWebView? {
        await waitForWebViews(count: 1, in: rootView).first
    }

    private func waitForWebViews(count: Int, in rootView: NSView) async -> [WKWebView] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))

        while clock.now < deadline {
            rootView.layoutSubtreeIfNeeded()
            let webViews = descendants(of: WKWebView.self, in: rootView)
            if webViews.count == count {
                return webViews
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return descendants(of: WKWebView.self, in: rootView)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }

    private func descendants<ViewType: NSView>(
        of type: ViewType.Type,
        in rootView: NSView
    ) -> [ViewType] {
        rootView.subviews.flatMap { subview in
            let current = (subview as? ViewType).map { [$0] } ?? []
            return current + descendants(of: type, in: subview)
        }
    }
}

private struct ReaderOverlapHarness: View {
    let store: StoreOf<ReaderFeature>
    @State private var session = ReaderWebSession()

    var body: some View {
        ZStack {
            ReaderScreen(store: store, session: session)
            ReaderScreen(store: store, session: session)
        }
    }
}

#endif
