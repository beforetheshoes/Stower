import ComposableArchitecture
import Foundation

@Reducer
public struct SidebarFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var selection: LibraryFilter = .all
        public var counts: LibraryListCounts = .zero
        public var tags: [Tag] = []
        public var isLoading = false
        public var errorMessage: String?
        /// Bound to the "New Tag" sheet.
        public var isCreatingTag: Bool = false
        public var newTagName: String = ""
        /// Non-nil when the user is renaming a tag — holds the working name.
        public var renamingTag: RenameState?

        public struct RenameState: Equatable {
            public var tagID: UUID
            public var name: String
            public init(tagID: UUID, name: String) {
                self.tagID = tagID
                self.name = name
            }
        }

        public init() {}
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case loaded(LibraryListCounts, [Tag])
        case failed(String)
        case selectList(LibraryFilter)

        case newTagTapped
        case newTagDismissed
        case newTagNameChanged(String)
        case newTagConfirmed
        case tagCreated(Tag)

        case renameTagTapped(Tag)
        case renameTagDismissed
        case renameTagNameChanged(String)
        case renameTagConfirmed
        case tagRenamed

        case deleteTagTapped(UUID)
        case tagDeleted

        case observedChange
    }

    @Dependency(\.stowerRepository) var repository

    enum CancelID: Hashable { case observeChanges }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                let repository = self.repository
                return .merge(
                    .send(.reload),
                    .run { send in
                        for await _ in repository.observeLibraryChanges() {
                            await send(.observedChange)
                        }
                    }
                    .cancellable(id: CancelID.observeChanges, cancelInFlight: true)
                )

            case .reload:
                state.isLoading = true
                state.errorMessage = nil
                let repository = self.repository
                return .run { send in
                    do {
                        async let counts = repository.fetchListCounts()
                        async let tags = repository.fetchTags()
                        let pair = try await (counts, tags)
                        await send(.loaded(pair.0, pair.1))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .loaded(let counts, let tags):
                state.isLoading = false
                state.counts = counts
                state.tags = tags
                // If the currently selected tag was deleted elsewhere, fall
                // back to All so the library doesn't get stuck on a ghost.
                if case .tag(let id) = state.selection,
                   !tags.contains(where: { $0.id == id }) {
                    state.selection = .all
                }
                return .none

            case .failed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none

            case .selectList(let filter):
                state.selection = filter
                return .none

            case .newTagTapped:
                state.isCreatingTag = true
                state.newTagName = ""
                return .none

            case .newTagDismissed:
                state.isCreatingTag = false
                state.newTagName = ""
                return .none

            case .newTagNameChanged(let value):
                state.newTagName = value
                return .none

            case .newTagConfirmed:
                let name = state.newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .none }
                state.isCreatingTag = false
                state.newTagName = ""
                let repository = self.repository
                return .run { send in
                    do {
                        let tag = try await repository.createTag(name, nil)
                        await send(.tagCreated(tag))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .tagCreated:
                return .send(.reload)

            case .renameTagTapped(let tag):
                state.renamingTag = .init(tagID: tag.id, name: tag.name)
                return .none

            case .renameTagDismissed:
                state.renamingTag = nil
                return .none

            case .renameTagNameChanged(let value):
                state.renamingTag?.name = value
                return .none

            case .renameTagConfirmed:
                guard let rename = state.renamingTag else { return .none }
                state.renamingTag = nil
                let name = rename.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .none }
                let repository = self.repository
                let id = rename.tagID
                return .run { send in
                    do {
                        try await repository.renameTag(id, name)
                        await send(.tagRenamed)
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .tagRenamed:
                return .send(.reload)

            case .deleteTagTapped(let id):
                // If the deleted tag is selected, unfilter back to All.
                if case .tag(let selectedID) = state.selection, selectedID == id {
                    state.selection = .all
                }
                let repository = self.repository
                return .run { send in
                    do {
                        try await repository.deleteTag(id)
                        await send(.tagDeleted)
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .tagDeleted:
                return .send(.reload)

            case .observedChange:
                return .send(.reload)
            }
        }
    }
}
