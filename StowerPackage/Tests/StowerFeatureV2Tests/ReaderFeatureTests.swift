import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct ReaderFeatureTests {
    @Test
    func viewportWidthChange_updatesState() async {
        let itemID = UUID()

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        }

        await store.send(.viewportWidthChanged(375)) {
            $0.viewportWidth = 375
        }
    }

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
            $0.continuousClock = TestClock()
            $0.readerProgressClient = .noop
            $0.stowerRepository.loadItem = { _ in item }
            $0.stowerRepository.loadReaderDocument = { _ in document }
            $0.stowerRepository.loadSourceHTML = { _ in nil }
        }
        // `.loaded` kicks off a long-running progress-polling effect that
        // this test isn't verifying. Turn off exhaustive effect assertion
        // so TCA doesn't flag the still-running poll loop at teardown.
        store.exhaustivity = .off(showSkippedAssertions: false)

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
    func backgroundChange_updatesStateAndSaves() async {
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

        await store.send(.backgroundChanged(.black)) {
            $0.appearance.background = .black
        }
        await store.receive(.saveAppearance)
        await clock.advance(by: .milliseconds(200))
        await store.receive(.saveAppearanceFinished)

        #expect(saved.value?.background == .black)
    }

    @Test
    func primaryAccentChange_updatesStateAndSaves() async {
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

        await store.send(.primaryAccentChanged(.magenta)) {
            $0.appearance.primaryAccent = .magenta
        }
        await store.receive(.saveAppearance)
        await clock.advance(by: .milliseconds(200))
        await store.receive(.saveAppearanceFinished)

        #expect(saved.value?.primaryAccent == .magenta)
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
    func lineWidthChange_clampsToViewportRange_beforeSaving() async {
        let itemID = UUID()
        let clock = TestClock()
        let saved = LockIsolated<ReaderAppearanceSettings?>(nil)
        let policy = ReaderLineWidthPolicy(viewportWidth: 375)

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.stowerRepository.saveReaderAppearanceSettings = { settings in
                saved.withValue { $0 = settings }
            }
        }

        await store.send(.viewportWidthChanged(375)) {
            $0.viewportWidth = 375
        }
        await store.send(.lineWidthChanged(980)) {
            $0.appearance.lineWidth = policy.range.upperBound
        }
        await store.receive(.saveAppearance)
        await clock.advance(by: .milliseconds(200))
        await store.receive(.saveAppearanceFinished)

        #expect(saved.value?.lineWidth == policy.range.upperBound)
    }

    @Test
    func contentAreaTapped_togglesChromeVisibility() async {
        let itemID = UUID()

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        }

        await store.send(.contentAreaTapped) {
            $0.isChromeHidden = true
        }
        await store.send(.contentAreaTapped) {
            $0.isChromeHidden = false
        }
    }

    @Test
    func loadWithDefaultAppearance_usesDefaults() async {
        let itemID = UUID()
        let item = SavedItem(id: itemID, title: "Read", content: "Body")
        let document = ReaderDocument(title: "Read", blocks: [.paragraph([.text("Body")])])

        let store = TestStore(initialState: ReaderFeature.State(itemID: itemID)) {
            ReaderFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.readerProgressClient = .noop
            $0.stowerRepository.loadItem = { _ in item }
            $0.stowerRepository.loadReaderDocument = { _ in document }
            $0.stowerRepository.loadSourceHTML = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

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
