import ComposableArchitecture
import Testing
@testable import StowerFeature

@MainActor
@Suite
struct LibraryFeatureTests {
    @Test
    func reloadPopulatesItems() async {
        let expected = [
            SavedItem(title: "Alpha", sourceURL: "https://a.com", content: "A"),
            SavedItem(title: "Beta", sourceURL: "https://b.com", content: "B"),
        ]

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.fetchLibrary = { expected }
        }

        await store.send(LibraryFeature.Action.reload) {
            $0.isLoading = true
        }
        await store.receive(LibraryFeature.Action.response(expected)) {
            $0.isLoading = false
            $0.items = expected
        }
    }

    @Test
    func searchUsesLocalizedContains() {
        var state = LibraryFeature.State()
        state.items = [
            SavedItem(title: "Swift Concurrency", sourceURL: nil, content: ""),
            SavedItem(title: "Feed Reader", sourceURL: nil, content: ""),
        ]
        state.query = "swift"

        #expect(state.filteredItems.count == 1)
        #expect(state.filteredItems[0].title == "Swift Concurrency")
    }

    @Test
    func saveURLAddsHttpsWhenSchemeMissing() async {
        let item = SavedItem(title: "Saved", sourceURL: "https://example.com/post", content: "Body")

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.urlIngestionClient.ingest = { url in
                #expect(url.absoluteString == "https://example.com/post")
                return IngestionResult.sharedText("ok")
            }
            $0.stowerRepository.createItemFromIngestion = { _ in item }
            $0.stowerRepository.fetchLibrary = { [item] }
        }

        await store.send(.sourceURLChanged("example.com/post")) {
            $0.sourceURL = "example.com/post"
        }
        await store.send(.saveURLTapped) {
            $0.isSaving = true
            $0.saveState = .extracting
        }
        await store.receive(.saveURLFinished(item)) {
            $0.isSaving = false
            $0.saveState = .ready
            $0.sourceURL = ""
        }
        await store.receive(.openItem(item.id))
        await store.receive(.reload) {
            $0.isLoading = true
        }
        await store.receive(.response([item])) {
            $0.isLoading = false
            $0.items = [item]
        }
    }
}
