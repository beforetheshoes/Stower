import ComposableArchitecture
import Foundation
import Testing
@testable import StowerData
@testable import StowerFeature

@MainActor
@Suite
struct ReaderFeatureTests {
    @Test
    func effectiveRenderFormat_defaultsToItemRenderFormat_forInteractiveArticles() {
        // Regression: previously `effectiveRenderFormat` always returned
        // `.structuredV1` when no manual override was set, which silently
        // broke every SVG-rich article (joshwcomeau.com, ngrok.com blog,
        // etc.). It must fall back to the item's ingestion-detected format.
        let webViewItem = SavedItem(
            title: "Interactive SVG",
            renderFormat: .webView,
            content: "Body"
        )
        var state = ReaderFeature.State(item: webViewItem)
        #expect(state.effectiveRenderFormat == .webView)
        #expect(state.hasInteractiveContent)

        // Structured items still default to structured.
        let structuredItem = SavedItem(
            title: "Plain article",
            renderFormat: .structuredV1,
            content: "Body"
        )
        state = ReaderFeature.State(item: structuredItem)
        #expect(state.effectiveRenderFormat == .structuredV1)
        #expect(!state.hasInteractiveContent)
    }

    @Test
    func effectiveRenderFormat_manualOverride_takesPrecedenceOverItemFormat() {
        let webViewItem = SavedItem(
            title: "Interactive SVG",
            renderFormat: .webView,
            content: "Body"
        )
        var state = ReaderFeature.State(item: webViewItem)
        state.renderModeOverride = .structuredV1
        #expect(state.effectiveRenderFormat == .structuredV1)

        state.renderModeOverride = .webView
        #expect(state.effectiveRenderFormat == .webView)
    }

    @Test
    func effectiveRenderFormat_withoutItem_fallsBackToStructured() {
        let state = ReaderFeature.State(itemID: UUID())
        #expect(state.effectiveRenderFormat == .structuredV1)
    }

    @Test
    func load_populatesItemAndDocument() async {
        let itemID = UUID()
        let item = SavedItem(id: itemID, title: "Read", content: "Body")
        let document = ReaderDocument(title: "Read", blocks: [.paragraph([.text("Body")])])

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        } withDependencies: {
            $0.stowerRepository.loadItem = { _ in item }
            $0.stowerRepository.loadReaderDocument = { _ in document }
            $0.stowerRepository.loadSourceHTML = { _ in nil }
        }

        await store.send(.load) {
            $0.isLoading = true
        }
        await store.receive(.loaded(item, document, nil)) {
            $0.isLoading = false
            $0.item = item
            $0.document = document
        }
    }

    @Test
    func fontSizeChange_updatesStateAndSaves() async {
        let itemID = UUID()
        let clock = TestClock()
        let saved = LockIsolated<ReaderAppearanceSettings?>(nil)

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.stowerRepository.saveReaderAppearanceSettings = { settings in
                saved.withValue { $0 = settings }
            }
        }

        await store.send(.fontSizeChanged(24)) {
            $0.appearance.fontSize = 24
        }
        await store.receive(.saveAppearance)
        await clock.advance(by: .milliseconds(200))
        await store.receive(.saveAppearanceFinished)

        #expect(saved.value?.fontSize == 24)
    }

    @Test
    func themeChange_updatesStateAndSaves() async {
        let itemID = UUID()
        let clock = TestClock()
        let saved = LockIsolated<ReaderAppearanceSettings?>(nil)

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.stowerRepository.saveReaderAppearanceSettings = { settings in
                saved.withValue { $0 = settings }
            }
        }

        await store.send(.themeChanged(.dark)) {
            $0.appearance.theme = .dark
        }
        await store.receive(.saveAppearance)
        await clock.advance(by: .milliseconds(200))
        await store.receive(.saveAppearanceFinished)

        #expect(saved.value?.theme == .dark)
    }

    @Test
    func saveFailure_setsErrorWithoutRevertingLocalValue() async {
        let itemID = UUID()
        let clock = TestClock()

        enum SaveError: Error {
            case failed
        }

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.stowerRepository.saveReaderAppearanceSettings = { _ in
                throw SaveError.failed
            }
        }

        await store.send(.lineWidthChanged(760)) {
            $0.appearance.lineWidth = 760
        }
        await store.receive(.saveAppearance)
        await clock.advance(by: .milliseconds(200))
        await store.receive(.saveAppearanceFailed(SaveError.failed.localizedDescription)) {
            $0.errorMessage = SaveError.failed.localizedDescription
        }
        #expect(store.state.appearance.lineWidth == 760)
    }

    @Test
    func loadWithDefaultAppearance_usesDefaults() async {
        let itemID = UUID()
        let item = SavedItem(id: itemID, title: "Read", content: "Body")
        let document = ReaderDocument(title: "Read", blocks: [.paragraph([.text("Body")])])

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        } withDependencies: {
            $0.stowerRepository.loadItem = { _ in item }
            $0.stowerRepository.loadReaderDocument = { _ in document }
            $0.stowerRepository.loadSourceHTML = { _ in nil }
        }

        #expect(store.state.appearance == ReaderAppearanceSettings())

        await store.send(.load) {
            $0.isLoading = true
        }
        await store.receive(.loaded(item, document, nil)) {
            $0.isLoading = false
            $0.item = item
            $0.document = document
        }
    }
}
