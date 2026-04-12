import ComposableArchitecture
import Foundation
@testable import StowerFeature
import Testing

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
            $0.stowerRepository.fetchLibrary = { _ in expected }
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
    func filterChanged_triggersReloadWithNewFilter() async {
        let unreadItem = SavedItem(title: "U", content: "", isRead: false)
        let readItem = SavedItem(title: "R", content: "", isRead: true)

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.fetchLibrary = { filter in
                switch filter {
                case .read:
                    return [readItem]
                case .unread:
                    return [unreadItem]
                default:
                    return [unreadItem, readItem]
                }
            }
        }

        await store.send(.filterChanged(.read)) {
            $0.filter = .read
        }
        await store.receive(.reload) { $0.isLoading = true }
        await store.receive(.response([readItem])) {
            $0.isLoading = false
            $0.items = [readItem]
        }
    }

    @Test
    func toggleStar_whileViewingStarred_removesRow() async {
        let starred = SavedItem(title: "S", content: "", isStarred: true)
        var initial = LibraryFeature.State()
        initial.filter = .starred
        initial.items = [starred]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.setStarred = { _, _ in }
        }

        await store.send(.toggleStar(starred.id)) {
            $0.items = []
        }
    }

    @Test
    func deleteItem_inAllFilter_removesOptimistically() async {
        let item = SavedItem(title: "Doomed", content: "")
        var initial = LibraryFeature.State()
        initial.items = [item]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.deleteItem = { _ in }
        }

        await store.send(.deleteItem(item.id)) {
            $0.items = []
        }
        await store.receive(.deleteFinished)
    }

    @Test
    func deleteItem_inTrashFilter_keepsRowVisible() async {
        let item = SavedItem(title: "Already deleted", content: "")
        var initial = LibraryFeature.State()
        initial.filter = .recentlyDeleted
        initial.items = [item]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.deleteItem = { _ in }
        }

        await store.send(.deleteItem(item.id))
        await store.receive(.deleteFinished)
        #expect(store.state.items.count == 1)
    }

    @Test
    func permanentlyDelete_removesRow() async {
        let item = SavedItem(title: "Gone", content: "")
        var initial = LibraryFeature.State()
        initial.filter = .recentlyDeleted
        initial.items = [item]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.permanentlyDelete = { _ in }
        }

        await store.send(.permanentlyDelete(item.id)) {
            $0.items = []
        }
        await store.receive(.deleteFinished)
    }

    @Test
    func toggleTagOnItem_addsTagOptimistically() async {
        let tagID = UUID()
        let item = SavedItem(title: "Untagged", content: "")
        var initial = LibraryFeature.State()
        initial.items = [item]
        initial.availableTags = [Tag(id: tagID, name: "work")]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.addTag = { _, _ in }
        }

        await store.send(.toggleTagOnItem(item.id, tagID)) {
            $0.items[0].tagIDs = [tagID]
        }
    }

    @Test
    func toggleTagOnItem_removesTagOptimistically() async {
        let tagID = UUID()
        let item = SavedItem(title: "Tagged", content: "", tagIDs: [tagID])
        var initial = LibraryFeature.State()
        initial.items = [item]
        initial.availableTags = [Tag(id: tagID, name: "work")]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.removeTag = { _, _ in }
        }

        await store.send(.toggleTagOnItem(item.id, tagID)) {
            $0.items[0].tagIDs = []
        }
    }

    @Test
    func toggleTagOnItem_whileViewingUntagged_dropsRowWhenTagAdded() async {
        let tagID = UUID()
        let item = SavedItem(title: "Orphan", content: "")
        var initial = LibraryFeature.State()
        initial.filter = .untagged
        initial.items = [item]
        initial.availableTags = [Tag(id: tagID, name: "work")]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.addTag = { _, _ in }
        }

        await store.send(.toggleTagOnItem(item.id, tagID)) {
            $0.items = []
        }
    }

    @Test
    func toggleTagOnItem_whileViewingTagFilter_dropsRowWhenTagRemoved() async {
        let tagID = UUID()
        let otherTag = UUID()
        let item = SavedItem(title: "Tagged", content: "", tagIDs: [tagID, otherTag])
        var initial = LibraryFeature.State()
        initial.filter = .tag(tagID)
        initial.items = [item]
        initial.availableTags = [
            Tag(id: tagID, name: "work"),
            Tag(id: otherTag, name: "later"),
        ]

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.removeTag = { _, _ in }
        }

        await store.send(.toggleTagOnItem(item.id, tagID)) {
            $0.items = []
        }
    }

    @Test
    func reloadTags_populatesAvailableTags() async {
        let tags = [Tag(name: "a"), Tag(name: "b")]
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.fetchTags = { tags }
        }

        await store.send(.reloadTags)
        await store.receive(.tagsLoaded(tags)) {
            $0.availableTags = tags
        }
    }

    // MARK: - Inline Tag Creation

    @Test
    func inlineCreateTag_createsAndAssigns() async {
        let item = SavedItem(title: "Article", content: "")
        let newTag = Tag(name: "reading", colorHex: FlexokiRaw.shade(.red, 600))
        var initial = LibraryFeature.State()
        initial.items = [item]
        initial.availableTags = []

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.createTag = { _, _ in newTag }
            $0.stowerRepository.addTag = { _, _ in }
            $0.stowerRepository.fetchTags = { [newTag] }
        }

        let suggestedColor = TagColorSuggester.suggestColor(existingHexValues: [])
        await store.send(.inlineCreateTagTapped(item.id)) {
            $0.inlineTagCreation = LibraryFeature.InlineTagCreation(
                itemID: item.id,
                colorHex: suggestedColor
            )
        }
        await store.send(.inlineCreateTagNameChanged("reading")) {
            $0.inlineTagCreation?.name = "reading"
        }
        await store.send(.inlineCreateTagConfirmed) {
            $0.inlineTagCreation = nil
        }
        await store.receive(.inlineTagCreated(newTag, item.id)) {
            $0.availableTags = [newTag]
            $0.items[0].tagIDs = [newTag.id]
        }
        await store.receive(.reloadTags)
        await store.receive(.tagsLoaded([newTag]))
    }

    @Test
    func inlineCreateTag_emptyName_isNoOp() async {
        let item = SavedItem(title: "Article", content: "")
        var initial = LibraryFeature.State()
        initial.items = [item]
        initial.inlineTagCreation = LibraryFeature.InlineTagCreation(itemID: item.id)

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        }

        await store.send(.inlineCreateTagConfirmed) {
            $0.inlineTagCreation = nil
        }
        // No effects — createTag and addTag should NOT be called.
    }

    @Test
    func inlineCreateTag_dismiss_clearsState() async {
        let item = SavedItem(title: "Article", content: "")
        var initial = LibraryFeature.State()
        initial.inlineTagCreation = LibraryFeature.InlineTagCreation(itemID: item.id, name: "wip")

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        }

        await store.send(.inlineCreateTagDismissed) {
            $0.inlineTagCreation = nil
        }
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
            $0.items = [item]
        }
        await store.receive(.openItem(item))
    }
}
