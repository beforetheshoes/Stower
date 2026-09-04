import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

/// Library behavior is driven by database observation, so these tests run
/// against a real (temporary) database and assert on what observation
/// delivers rather than on hand-rolled reload actions.
@MainActor
@Suite(.dependencies { try $0.bootstrapStowerDatabase(enableSync: false) })
struct LibraryFeatureTests {
    @Dependency(\.stowerRepository)
    var repository

    @Test
    func defaultsToInboxWithCompactNewestFirstLayout() {
        let state = LibraryFeature.State()
        #expect(state.filter == .unread)
        #expect(state.displayStyle == .compact)
        #expect(state.sortOrder == .newestFirst)
        #expect(!state.hasLoaded)
        #expect(state.items.isEmpty)
    }

    @Test
    func onAppearObservesInboxRows() async throws {
        let unread = try await seed(title: "Unread article")
        var readItem = try await seed(title: "Read article")
        try await repository.setReadStatus(readItem.id, true)
        readItem.isRead = true

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded) {
            $0.hasLoaded = true
        }
        #expect(store.state.items.map(\.id) == [unread.id])
        #expect(store.state.availableTags.isEmpty)
    }

    @Test
    func markingReadRemovesRowFromInboxThroughObservation() async throws {
        let item = try await seed(title: "Finish me")
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [item.id])

        await store.send(.toggleRead(item.id))
        try await eventually { store.state.items.isEmpty }
        #expect(try await repository.loadItem(item.id)?.isRead == true)
    }

    @Test
    func filterChangeReloadsObservedQueryAndClearsSearch() async throws {
        let item = try await seed(title: "Finished")
        try await repository.setReadStatus(item.id, true)

        var initial = LibraryFeature.State()
        initial.query = "fin"
        let store = TestStore(initialState: initial) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)
        #expect(store.state.items.isEmpty)

        await store.send(.filterChanged(.read)) {
            $0.filter = .read
            $0.query = ""
        }
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [item.id])
    }

    @Test
    func searchIsDebouncedAndMatchesBodyText() async throws {
        let match = try await seed(title: "Alpha", body: "The quick brown fox")
        _ = try await seed(title: "Beta", body: "Nothing to see")
        let clock = TestClock()

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)
        #expect(store.state.items.count == 2)

        await store.send(.queryChanged("brown")) {
            $0.query = "brown"
        }
        await clock.advance(by: .milliseconds(150))
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [match.id])
        // Body text travels with search results so the row can show a snippet.
        #expect(store.state.items[0].content.contains("brown fox"))
    }

    @Test
    func sortOrderChangeReversesObservedRows() async throws {
        let first = try await seed(title: "First")
        let second = try await seed(title: "Second")

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [second.id, first.id])

        await store.send(.sortOrderChanged(.oldestFirst)) {
            $0.sortOrder = .oldestFirst
        }
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [first.id, second.id])
    }

    @Test
    func toggleStarWhileViewingStarredRemovesRow() async throws {
        let item = try await seed(title: "Starred")
        try await repository.setStarred(item.id, true)

        var initial = LibraryFeature.State()
        initial.filter = .starred
        let store = TestStore(initialState: initial) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [item.id])

        await store.send(.toggleStar(item.id))
        try await eventually { store.state.items.isEmpty }
    }

    @Test
    func deleteMovesRowToTrashAndBack() async throws {
        let item = try await seed(title: "Doomed")
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)

        await store.send(.deleteItem(item.id))
        await store.receive(.deleteFinished)
        try await eventually { store.state.items.isEmpty }

        await store.send(.filterChanged(.recentlyDeleted)) {
            $0.filter = .recentlyDeleted
        }
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [item.id])

        await store.send(.restoreFromTrash(item.id))
        await store.receive(.deleteFinished)
        try await eventually { store.state.items.isEmpty }
    }

    @Test
    func toggleTagOnItemAssignsAndUnassignsThroughObservation() async throws {
        let item = try await seed(title: "Taggable")
        let tag = try await repository.createTag("work", nil)

        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)
        #expect(store.state.availableTags.map(\.id) == [tag.id])
        #expect(store.state.items[0].tagIDs.isEmpty)

        await store.send(.toggleTagOnItem(item.id, tag.id))
        try await eventually { store.state.items.first?.tagIDs == [tag.id] }

        await store.send(.toggleTagOnItem(item.id, tag.id))
        try await eventually { store.state.items.first?.tagIDs.isEmpty == true }
    }

    @Test
    func toggleTagWhileViewingUntaggedDropsRow() async throws {
        let item = try await seed(title: "Orphan")
        let tag = try await repository.createTag("work", nil)

        var initial = LibraryFeature.State()
        initial.filter = .untagged
        let store = TestStore(initialState: initial) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)
        #expect(store.state.items.map(\.id) == [item.id])

        await store.send(.toggleTagOnItem(item.id, tag.id))
        try await eventually { store.state.items.isEmpty }
    }

    // MARK: - Inline Tag Creation

    @Test
    func inlineCreateTagCreatesAssignsAndObserves() async throws {
        let item = try await seed(title: "Article")
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(.libraryLoaded)

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
        await store.receive(\.inlineTagCreated)
        try await eventually {
            store.state.availableTags.map(\.name) == ["reading"]
                && store.state.items.first?.tagIDs.count == 1
        }
    }

    @Test
    func inlineCreateTag_emptyName_isNoOp() async {
        var initial = LibraryFeature.State()
        initial.inlineTagCreation = LibraryFeature.InlineTagCreation(itemID: UUID())

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        }

        await store.send(.inlineCreateTagConfirmed) {
            $0.inlineTagCreation = nil
        }
    }

    @Test
    func inlineCreateTag_dismiss_clearsState() async {
        var initial = LibraryFeature.State()
        initial.inlineTagCreation = LibraryFeature.InlineTagCreation(itemID: UUID(), name: "wip")

        let store = TestStore(initialState: initial) {
            LibraryFeature()
        }

        await store.send(.inlineCreateTagDismissed) {
            $0.inlineTagCreation = nil
        }
    }

    // MARK: - Saving

    @Test
    func browserExtensionSaveQueuesTheLinkWithoutOpeningReader() async throws {
        let url = try #require(URL(string: "https://example.com/reference"))
        let queued = LockIsolated<[(IngestionJob.Kind, String)]>([])
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.enqueueIngestionJob = { kind, payload in
                queued.withValue { $0.append((kind, payload)) }
            }
        }

        await store.send(.saveExternalURL(url))
        await store.receive(.urlQueued(url)) {
            $0.queuedSaveCount = 1
        }
        #expect(queued.value.count == 1)
        #expect(queued.value.first?.0 == .url)
        #expect(queued.value.first?.1 == url.absoluteString)
    }

    @Test
    func saveURLAddsHttpsWhenSchemeMissingAndClearsTheField() async throws {
        let queued = LockIsolated<[String]>([])
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.enqueueIngestionJob = { _, payload in
                queued.withValue { $0.append(payload) }
            }
        }

        await store.send(.sourceURLChanged("example.com/post")) {
            $0.sourceURL = "example.com/post"
        }
        await store.send(.saveURLTapped)
        await store.receive(.urlQueued(try #require(URL(string: "https://example.com/post")))) {
            $0.sourceURL = ""
            $0.queuedSaveCount = 1
        }
        #expect(queued.value == ["https://example.com/post"])
    }

    @Test
    func queueFailureIsReportedOnTheForm() async throws {
        struct QueueError: Error, LocalizedError {
            var errorDescription: String? { "Database is busy." }
        }
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        } withDependencies: {
            $0.stowerRepository.enqueueIngestionJob = { _, _ in throw QueueError() }
        }

        await store.send(.sourceURLChanged("https://example.com/post")) {
            $0.sourceURL = "https://example.com/post"
        }
        await store.send(.saveURLTapped)
        await store.receive(.saveURLFailed("Database is busy.")) {
            $0.saveState = .failed
            $0.errorMessage = "Database is busy."
        }
    }

    @Test
    func invalidURLFailsWithoutSaving() async {
        let store = TestStore(initialState: LibraryFeature.State()) {
            LibraryFeature()
        }

        await store.send(.sourceURLChanged("not a url")) {
            $0.sourceURL = "not a url"
        }
        await store.send(.saveURLTapped) {
            $0.errorMessage = "Enter a valid source URL."
            $0.saveState = .failed
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func seed(title: String, body: String = "Body text") async throws -> SavedItem {
        var ingestion = IngestionResult.sharedText(body)
        ingestion.title = title
        return try await repository.createItemFromIngestion(ingestion)
    }
}

/// Waits for a database observation to deliver, polling the store's state.
@MainActor
func eventually(
    timeout: Duration = .seconds(3),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "Condition not met before timeout", sourceLocation: sourceLocation)
}
