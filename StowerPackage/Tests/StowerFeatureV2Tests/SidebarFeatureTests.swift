import ComposableArchitecture
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite
struct SidebarFeatureTests {
    @Test
    func reload_loadsCountsAndTags() async {
        let counts = LibraryListCounts(
            unread: 2,
            read: 1,
            starred: 1,
            untagged: 1,
            all: 3,
            recentlyDeleted: 1,
            byTag: [:]
        )
        let tag = Tag(name: "inbox")

        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.stowerRepository.fetchListCounts = { counts }
            $0.stowerRepository.fetchTags = { [tag] }
        }

        await store.send(.reload) { $0.isLoading = true }
        await store.receive(.loaded(counts, [tag])) {
            $0.isLoading = false
            $0.counts = counts
            $0.tags = [tag]
        }
    }

    @Test
    func selectList_updatesSelection() async {
        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        }

        await store.send(.selectList(.starred)) {
            $0.selection = .starred
        }
    }

    @Test
    func newTag_confirmCreatesAndReloads() async {
        let tag = Tag(name: "ai")
        let counts = LibraryListCounts(all: 0)

        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.stowerRepository.createTag = { _, _ in tag }
            $0.stowerRepository.fetchListCounts = { counts }
            $0.stowerRepository.fetchTags = { [tag] }
        }

        await store.send(.newTagTapped) {
            $0.isCreatingTag = true
            $0.newTagName = ""
        }
        await store.send(.newTagNameChanged("ai")) {
            $0.newTagName = "ai"
        }
        await store.send(.newTagConfirmed) {
            $0.isCreatingTag = false
            $0.newTagName = ""
        }
        await store.receive(.tagCreated(tag))
        await store.receive(.reload) { $0.isLoading = true }
        await store.receive(.loaded(counts, [tag])) {
            $0.isLoading = false
            $0.counts = counts
            $0.tags = [tag]
        }
    }

    @Test
    func deleteTag_whileSelected_fallsBackToAll() async {
        let id = UUID()
        var state = SidebarFeature.State()
        state.selection = .tag(id)

        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.stowerRepository.deleteTag = { _ in }
            $0.stowerRepository.fetchListCounts = { .zero }
            $0.stowerRepository.fetchTags = { [] }
        }

        await store.send(.deleteTagTapped(id)) {
            $0.selection = .all
        }
        await store.receive(.tagDeleted)
        await store.receive(.reload) { $0.isLoading = true }
        await store.receive(.loaded(.zero, [])) {
            $0.isLoading = false
        }
    }

    @Test
    func loaded_dropsSelectionOfDeletedTag() async {
        let ghostID = UUID()
        var state = SidebarFeature.State()
        state.selection = .tag(ghostID)

        let store = TestStore(initialState: state) {
            SidebarFeature()
        }

        await store.send(.loaded(.zero, [])) {
            $0.counts = .zero
            $0.tags = []
            $0.selection = .all
        }
    }
}
