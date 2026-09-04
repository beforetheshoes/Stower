import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@MainActor
@Suite(.dependencies { try $0.bootstrapStowerDatabase(enableSync: false) })
struct SidebarFeatureTests {
    @Dependency(\.stowerRepository)
    var repository

    @Test
    func defaultsToInbox() {
        #expect(SidebarFeature.State().selection == .unread)
    }

    @Test
    func onAppearObservesCountsAndTags() async throws {
        var ingestion = IngestionResult.sharedText("Body")
        ingestion.title = "Unread"
        let unread = try await repository.createItemFromIngestion(ingestion)
        ingestion.title = "Read"
        let readItem = try await repository.createItemFromIngestion(ingestion)
        try await repository.setReadStatus(readItem.id, true)
        let tag = try await repository.createTag("inbox", nil)
        try await repository.addTag(unread.id, tag.id)

        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.sidebarLoaded)
        #expect(store.state.counts.unread == 1)
        #expect(store.state.counts.read == 1)
        #expect(store.state.counts.all == 2)
        #expect(store.state.counts.untagged == 1)
        #expect(store.state.counts.byTag[tag.id] == 1)
        #expect(store.state.tags.map(\.id) == [tag.id])

        // A later write anywhere shows up without a reload action.
        try await repository.setReadStatus(unread.id, true)
        try await eventually { store.state.counts.unread == 0 && store.state.counts.read == 2 }
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
    func newTag_confirmCreatesAndIsObserved() async throws {
        let expectedColor = TagColorSuggester.suggestColor(existingHexValues: [])

        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.sidebarLoaded)

        await store.send(.newTagTapped) {
            $0.isCreatingTag = true
            $0.newTagName = ""
            $0.newTagColorHex = expectedColor
        }
        await store.send(.newTagNameChanged("ai")) {
            $0.newTagName = "ai"
        }
        await store.send(.newTagConfirmed) {
            $0.isCreatingTag = false
            $0.newTagName = ""
            $0.newTagColorHex = ""
        }
        await store.receive(\.tagCreated)
        try await eventually { store.state.tags.map(\.name) == ["ai"] }
        #expect(store.state.tags.first?.colorHex == expectedColor)
    }

    @Test
    func newTagConfirmed_passesAutoColor() async throws {
        _ = try await repository.createTag("work", FlexokiRaw.shade(.red, 600))
        let expectedColor = TagColorSuggester.suggestColor(
            existingHexValues: [FlexokiRaw.shade(.red, 600)]
        )
        let receivedColor = LockIsolated<String?>(nil)
        let newTag = Tag(name: "personal", colorHex: expectedColor)

        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.stowerRepository.createTag = { _, color in
                receivedColor.setValue(color)
                return newTag
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.sidebarLoaded)

        await store.send(.newTagTapped) {
            $0.isCreatingTag = true
            $0.newTagName = ""
            $0.newTagColorHex = expectedColor
        }
        await store.send(.newTagNameChanged("personal")) {
            $0.newTagName = "personal"
        }
        await store.send(.newTagConfirmed) {
            $0.isCreatingTag = false
            $0.newTagName = ""
            $0.newTagColorHex = ""
        }
        await store.receive(.tagCreated(newTag))

        // Red is taken, so orange-600 should have been passed.
        #expect(receivedColor.value == expectedColor)
        #expect(receivedColor.value == FlexokiRaw.shade(.orange, 600))
    }

    @Test
    func deleteTag_whileSelected_fallsBackToAll() async throws {
        let tag = try await repository.createTag("gone", nil)
        var state = SidebarFeature.State()
        state.selection = .tag(tag.id)

        let store = TestStore(initialState: state) {
            SidebarFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.sidebarLoaded)
        #expect(store.state.tags.map(\.id) == [tag.id])

        await store.send(.deleteTagTapped(tag.id)) {
            $0.selection = .all
        }
        await store.receive(.tagDeleted)
        try await eventually { store.state.tags.isEmpty }
    }

    @Test
    func sidebarLoaded_dropsSelectionOfMissingTag() async {
        var state = SidebarFeature.State()
        state.selection = .tag(UUID())

        let store = TestStore(initialState: state) {
            SidebarFeature()
        }

        await store.send(.sidebarLoaded) {
            $0.selection = .all
        }
    }
}
