#if os(macOS)
import AppKit
import ComposableArchitecture
import Observation
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

    @Test("Reader remains alive while entering and exiting focus mode")
    func focusTransitionDoesNotRebindWebPage() async throws {
        let model = ReaderFocusHarnessModel()
        let store = makeReaderStore()
        let hostingView = NSHostingView(
            rootView: ReaderFocusHarness(model: model, store: store)
        )
        let window = makeWindow(contentView: hostingView)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let initialWebView = await waitForWebView(in: hostingView)
        #expect(initialWebView != nil, "The test must mount the native WebView before changing focus.")

        for isFocused in [true, false, true, false] {
            model.setFocused(isFocused)
            try await Task.sleep(for: .milliseconds(400))
            hostingView.layoutSubtreeIfNeeded()

            let webViews = descendants(of: WKWebView.self, in: hostingView)
            #expect(webViews.count == 1, "The reader should have exactly one native WebView after a focus transition.")
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

@MainActor
@Observable
private final class ReaderFocusHarnessModel {
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isFocused = false

    func setFocused(_ newValue: Bool) {
        isFocused = newValue
    }
}

private struct ReaderFocusHarness: View {
    @Bindable var model: ReaderFocusHarnessModel
    let store: StoreOf<ReaderFeature>
    @State private var session = ReaderWebSession()

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            Text("Sidebar")
        } content: {
            Text("Library")
        } detail: {
            NavigationStack {
                ReaderScreen(
                    store: store,
                    session: session,
                    isReaderFocused: model.isFocused
                ) {
                    model.setFocused(model.isFocused == false)
                }
            }
        }
        .onChange(of: model.isFocused) { _, isFocused in
            model.columnVisibility = isFocused ? .detailOnly : .all
        }
    }
}
#endif
