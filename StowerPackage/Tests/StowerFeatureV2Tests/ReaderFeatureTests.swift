import ComposableArchitecture
import Foundation
import Testing
@testable import StowerFeature

@MainActor
@Suite
struct ReaderFeatureTests {
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
