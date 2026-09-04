import ComposableArchitecture
import Foundation
import SQLiteData

@Reducer
public struct SidebarFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var selection: LibraryFilter = .unread
        /// Database-observed counts and tags. Badges update on their own
        /// whenever an item or tag changes anywhere in the app.
        @Fetch public var sidebar = SidebarRequest.Value()
        public var errorMessage: String?
        /// Bound to the "New Tag" sheet.
        public var isCreatingTag: Bool = false
        public var newTagName: String = ""
        /// Selected color hex for tag creation — pre-populated with a suggestion.
        public var newTagColorHex: String = ""
        /// Non-nil when the user is renaming a tag — holds the working name.
        public var renamingTag: RenameState?

        public var counts: LibraryListCounts { sidebar.counts }
        public var tags: [Tag] { sidebar.tags }

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
        case sidebarLoaded
        case failed(String)
        case selectList(LibraryFilter)

        case newTagTapped
        case newTagDismissed
        case newTagNameChanged(String)
        case newTagColorChanged(String)
        case newTagConfirmed
        case tagCreated(Tag)

        case renameTagTapped(Tag)
        case renameTagDismissed
        case renameTagNameChanged(String)
        case renameTagConfirmed
        case tagRenamed

        case deleteTagTapped(UUID)
        case tagDeleted
    }

    @Dependency(\.stowerRepository)
    var repository

    enum CancelID: Hashable { case load }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                let sidebar = state.$sidebar
                return .run { send in
                    do {
                        try await sidebar.load(SidebarRequest(), animation: .default)
                        await send(.sidebarLoaded)
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case .sidebarLoaded:
                // If the currently selected tag was deleted elsewhere, fall
                // back to All so the library doesn't get stuck on a ghost.
                if case .tag(let id) = state.selection,
                   !state.tags.contains(where: { $0.id == id }) {
                    state.selection = .all
                }
                return .none

            case .failed(let error):
                state.errorMessage = error
                return .none

            case .selectList(let filter):
                state.selection = filter
                return .none

            case .newTagTapped:
                state.isCreatingTag = true
                state.newTagName = ""
                let existingHexes = state.tags.compactMap(\.colorHex)
                state.newTagColorHex = TagColorSuggester.suggestColor(
                    existingHexValues: existingHexes
                )
                return .none

            case .newTagDismissed:
                state.isCreatingTag = false
                state.newTagName = ""
                state.newTagColorHex = ""
                return .none

            case .newTagNameChanged(let value):
                state.newTagName = value
                return .none

            case .newTagColorChanged(let hex):
                state.newTagColorHex = hex
                return .none

            case .newTagConfirmed:
                let name = state.newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .none }
                let colorHex = state.newTagColorHex.isEmpty ? nil : state.newTagColorHex
                state.isCreatingTag = false
                state.newTagName = ""
                state.newTagColorHex = ""
                let repository = self.repository
                return .run { send in
                    do {
                        let tag = try await repository.createTag(name, colorHex)
                        await send(.tagCreated(tag))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .tagCreated:
                return .none

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
                return .none

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
                return .none
            }
        }
    }
}
