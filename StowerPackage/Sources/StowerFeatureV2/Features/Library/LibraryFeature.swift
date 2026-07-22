import ComposableArchitecture
import Foundation

@Reducer
public struct LibraryFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var items = [SavedItem]()
        public var query = ""
        public var sourceURL = ""
        public var isLoading = false
        public var isSaving = false
        public var saveState: ProcessingState = .queued
        public var errorMessage: String?
        /// Which list is currently being viewed. Drives `fetchLibrary(_:)`.
        public var filter: LibraryFilter = .unread
        public var displayStyle: LibraryDisplayStyle = .compact
        public var sortOrder: LibrarySortOrder = .newestFirst
        /// All tags known to the repository — drives the "Tags" submenu in the
        /// library row context menu. Refreshed lazily via observeLibraryChanges.
        public var availableTags = [Tag]()
        /// Non-nil when the user is creating a new tag inline from the tag submenu.
        public var inlineTagCreation: InlineTagCreation?
        /// Draft for the in-app text/markdown composer.
        public var textImportDraft: TextImportDraft?

        /// Library search matches against title, URL, site name, author,
        /// excerpt, AND full body text (`item.content`). The body-text
        /// component is what makes search work for PDFs rendered as page
        /// images — their visible content is `<img>` tags, so the only
        /// way to find a word inside a benefits summary from the library
        /// bar is to match against the extracted plainText that lives on
        /// the `SavedItem`. This is a linear scan over the visible
        /// library window, which is fine at typical library sizes; a
        /// future optimization could push this into a SQLite FTS5 index.
        public var filteredItems: [SavedItem] {
            let matches = query.isEmpty ? items : items.filter { item in
                if item.title.localizedStandardContains(query) {
                    return true
                }
                if let url = item.sourceURL, url.localizedStandardContains(query) {
                    return true
                }
                if let site = item.siteName, site.localizedStandardContains(query) {
                    return true
                }
                if let author = item.author, author.localizedStandardContains(query) {
                    return true
                }
                if let excerpt = item.excerpt, excerpt.localizedStandardContains(query) {
                    return true
                }
                if !item.content.isEmpty, item.content.localizedStandardContains(query) {
                    return true
                }
                return false
            }
            switch sortOrder {
            case .newestFirst:
                // Repository reads and optimistic inserts already arrive newest-first.
                // Keeping that order also preserves stable ties and selection indexes.
                return matches
            case .oldestFirst:
                return Array(matches.reversed())
            }
        }

        public init() {}
    }

    public struct InlineTagCreation: Equatable {
        public var itemID: UUID
        public var name: String = ""
        public var colorHex: String = ""

        public init(itemID: UUID, name: String = "", colorHex: String = "") {
            self.itemID = itemID
            self.name = name
            self.colorHex = colorHex
        }
    }

    public struct TextImportDraft: Equatable {
        public var title: String
        public var text: String
        public var mode: TextImportMode
        public var titleHint: String?

        public init(
            title: String = "",
            text: String = "",
            mode: TextImportMode = .auto,
            titleHint: String? = nil
        ) {
            self.title = title
            self.text = text
            self.mode = mode
            self.titleHint = titleHint
        }
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case response([SavedItem])
        case failed(String)
        case queryChanged(String)
        case filterChanged(LibraryFilter)
        case displayStyleChanged(LibraryDisplayStyle)
        case sortOrderChanged(LibrarySortOrder)
        case deleteItem(UUID)
        case deleteFinished
        case deleteFailed(String)
        case permanentlyDelete(UUID)
        case restoreFromTrash(UUID)
        case toggleStar(UUID)
        case toggleRead(UUID)
        case openItem(SavedItem)
        case reprocessItem(UUID)
        case reprocessFinished(SavedItem)
        case sourceURLChanged(String)
        case saveURLTapped
        case saveExternalURL(URL)
        case cancelURLSaveTapped
        case articleSaveFinished(ArticleSaveResult)
        case saveURLFinished(SavedItem)
        case saveURLFailed(String)
        case importPDFSelected(URL)
        case importWebsiteSelected(URL)
        case addTextTapped
        case textImportDismissed
        case textImportTitleChanged(String)
        case textImportTextChanged(String)
        case textImportModeChanged(TextImportMode)
        case saveTextImportTapped
        case importTextResolved(String, String?, TextImportMode)

        // Tag assignment
        case reloadTags
        case tagsLoaded([Tag])
        case refreshTagIDs
        case tagIDsRefreshed([UUID: [UUID]])
        case toggleTagOnItem(UUID, UUID)
        case observedChange

        // Inline tag creation
        case inlineCreateTagTapped(UUID)
        case inlineCreateTagNameChanged(String)
        case inlineCreateTagColorChanged(String)
        case inlineCreateTagConfirmed
        case inlineCreateTagDismissed
        case inlineTagCreated(Tag, UUID)
    }

    private enum CancelID: Hashable {
        case observeChanges
        case articleSave
        case articleRefresh
    }

    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.urlIngestionClient)
    var ingestionClient
    @Dependency(\.articleSaveClient)
    var articleSaveClient
    @Dependency(\.pdfIngestionClient)
    var pdfIngestionClient
    @Dependency(\.textIngestionClient)
    var textIngestionClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                let repository = self.repository
                return .merge(
                    .send(.reload),
                    .send(.reloadTags),
                    .run { send in
                        for await _ in repository.observeLibraryChanges() {
                            await send(.observedChange)
                        }
                    }
                    .cancellable(id: CancelID.observeChanges, cancelInFlight: true)
                )

            case .observedChange:
                // Refresh tag list and re-populate tagIDs on existing items.
                // We avoid re-fetching the full item list to preserve scroll
                // position and pending optimistic mutations.
                return .merge(
                    .send(.reloadTags),
                    .send(.refreshTagIDs)
                )

            case .reloadTags:
                let repository = self.repository
                return .run { send in
                    do {
                        let tags = try await repository.fetchTags()
                        await send(.tagsLoaded(tags))
                    } catch {
                        // Tag reload failure is non-critical — surface to
                        // errorMessage only if nothing else is showing.
                    }
                }

            case .tagsLoaded(let tags):
                state.availableTags = tags
                return .none

            case .refreshTagIDs:
                let ids = state.items.map(\.id)
                let repository = self.repository
                return .run { send in
                    let mapping = try await repository.fetchTagIDsByItem(ids)
                    await send(.tagIDsRefreshed(mapping))
                }

            case .tagIDsRefreshed(let mapping):
                for idx in state.items.indices {
                    let itemID = state.items[idx].id
                    if let tagIDs = mapping[itemID] {
                        state.items[idx].tagIDs = tagIDs
                    } else {
                        state.items[idx].tagIDs = []
                    }
                }
                return .none

            case let .toggleTagOnItem(itemID, tagID):
                guard let idx = state.items.firstIndex(where: { $0.id == itemID }) else {
                    return .none
                }
                let isApplied = state.items[idx].tagIDs.contains(tagID)
                if isApplied {
                    state.items[idx].tagIDs.removeAll { $0 == tagID }
                } else {
                    state.items[idx].tagIDs.append(tagID)
                }
                // If the current filter no longer matches this item, hide it.
                let remainingTags = state.items[idx].tagIDs
                switch state.filter {
                case .tag(let filterTagID) where !remainingTags.contains(filterTagID):
                    state.items.remove(at: idx)
                case .untagged where !remainingTags.isEmpty:
                    state.items.remove(at: idx)
                default:
                    break
                }
                let repository = self.repository
                let shouldAdd = !isApplied
                return .run { _ in
                    do {
                        if shouldAdd {
                            try await repository.addTag(itemID, tagID)
                        } else {
                            try await repository.removeTag(itemID, tagID)
                        }
                    } catch {
                        // Swallow — optimistic UI wins. A subsequent
                        // observeLibraryChanges ping will reconcile if needed.
                    }
                }

            case .inlineCreateTagTapped(let itemID):
                let suggestedColor = TagColorSuggester.suggestColor(
                    existingHexValues: state.availableTags.compactMap(\.colorHex)
                )
                state.inlineTagCreation = InlineTagCreation(
                    itemID: itemID,
                    colorHex: suggestedColor
                )
                return .none

            case .inlineCreateTagNameChanged(let name):
                state.inlineTagCreation?.name = name
                return .none

            case .inlineCreateTagColorChanged(let hex):
                state.inlineTagCreation?.colorHex = hex
                return .none

            case .inlineCreateTagDismissed:
                state.inlineTagCreation = nil
                return .none

            case .inlineCreateTagConfirmed:
                guard let creation = state.inlineTagCreation else { return .none }
                let name = creation.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let itemID = creation.itemID
                let colorHex = creation.colorHex.isEmpty ? nil : creation.colorHex
                state.inlineTagCreation = nil
                guard !name.isEmpty else { return .none }

                let repository = self.repository
                return .run { send in
                    let tag = try await repository.createTag(name, colorHex)
                    try await repository.addTag(itemID, tag.id)
                    await send(.inlineTagCreated(tag, itemID))
                }

            case let .inlineTagCreated(tag, itemID):
                if !state.availableTags.contains(where: { $0.id == tag.id }) {
                    state.availableTags.append(tag)
                }
                if let idx = state.items.firstIndex(where: { $0.id == itemID }),
                   !state.items[idx].tagIDs.contains(tag.id) {
                    state.items[idx].tagIDs.append(tag.id)
                }
                return .send(.reloadTags)

            case .reload:
                state.isLoading = true
                state.errorMessage = nil
                let repository = self.repository
                let filter = state.filter
                return .run { send in
                    do {
                        let items = try await repository.fetchLibrary(filter)
                        await send(.response(items))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .response(let items):
                state.isLoading = false
                state.items = items
                return .none

            case .failed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none

            case .queryChanged(let value):
                state.query = value
                return .none

            case .filterChanged(let filter):
                guard filter != state.filter else { return .none }
                state.filter = filter
                state.query = ""
                return .send(.reload)

            case .displayStyleChanged(let displayStyle):
                state.displayStyle = displayStyle
                return .none

            case .sortOrderChanged(let sortOrder):
                state.sortOrder = sortOrder
                return .none

            case .sourceURLChanged(let value):
                state.sourceURL = value
                if state.saveState == .failed {
                    state.saveState = .queued
                }
                return .none

            case .addTextTapped:
                state.textImportDraft = TextImportDraft()
                if state.saveState == .failed {
                    state.saveState = .queued
                    state.errorMessage = nil
                }
                return .none

            case .textImportDismissed:
                state.textImportDraft = nil
                return .none

            case .textImportTitleChanged(let title):
                state.textImportDraft?.title = title
                if state.saveState == .failed {
                    state.saveState = .queued
                    state.errorMessage = nil
                }
                return .none

            case .textImportTextChanged(let text):
                state.textImportDraft?.text = text
                if state.saveState == .failed {
                    state.saveState = .queued
                    state.errorMessage = nil
                }
                return .none

            case .textImportModeChanged(let mode):
                state.textImportDraft?.mode = mode
                return .none

            case .saveTextImportTapped:
                guard let draft = state.textImportDraft else { return .none }
                let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    state.errorMessage = "Enter some text or markdown."
                    state.saveState = .failed
                    return .none
                }
                state.isSaving = true
                state.saveState = .extracting
                state.errorMessage = nil
                return runTextImport(
                    .init(
                        text: text,
                        explicitTitle: draft.title,
                        titleHint: draft.titleHint,
                        mode: draft.mode,
                        openAfterSave: true
                    ),
                    repository: self.repository,
                    textIngestionClient: self.textIngestionClient
                )

            case let .importTextResolved(text, titleHint, mode):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "The selected file is empty."
                    state.saveState = .failed
                    return .none
                }
                state.isSaving = true
                state.saveState = .extracting
                state.errorMessage = nil
                return runTextImport(
                    .init(
                        text: trimmed,
                        explicitTitle: nil,
                        titleHint: titleHint,
                        mode: mode,
                        openAfterSave: false
                    ),
                    repository: self.repository,
                    textIngestionClient: self.textIngestionClient
                )

            case .saveURLTapped:
                let sourceURL = state.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let normalizedURL = normalizeSourceURL(sourceURL),
                      let url = URL(string: normalizedURL)
                else {
                    state.errorMessage = "Enter a valid source URL."
                    state.saveState = .failed
                    return .none
                }

                state.errorMessage = nil
                state.isSaving = true
                state.saveState = .extracting
                let articleSaveClient = self.articleSaveClient
                return .run { send in
                    do {
                        let saved = try await articleSaveClient.save(url)
                        await send(.articleSaveFinished(saved))
                        await send(.openItem(saved.item))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.saveURLFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.articleSave, cancelInFlight: true)

            case .saveExternalURL(let url):
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    state.errorMessage = "The browser shared an invalid URL."
                    state.saveState = .failed
                    return .none
                }

                state.errorMessage = nil
                state.isSaving = true
                state.saveState = .extracting
                let articleSaveClient = self.articleSaveClient
                return .run { send in
                    do {
                        let saved = try await articleSaveClient.save(url)
                        await send(.articleSaveFinished(saved))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.saveURLFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.articleSave, cancelInFlight: true)

            case .cancelURLSaveTapped:
                state.isSaving = false
                state.saveState = .queued
                state.errorMessage = nil
                return .cancel(id: CancelID.articleSave)

            case .articleSaveFinished(let result):
                state.isSaving = false
                state.saveState = result.state
                state.errorMessage = result.warnings.isEmpty
                    ? nil
                    : result.warnings.joined(separator: "\n")
                state.sourceURL = ""
                state.textImportDraft = nil
                if shouldShowInFilter(result.item, filter: state.filter) {
                    state.items.insert(result.item, at: 0)
                }
                return .none

            case .saveURLFinished(let item):
                state.isSaving = false
                state.saveState = item.processingState
                state.sourceURL = ""
                state.textImportDraft = nil
                // Only pre-insert if the current filter would include the new
                // item. Otherwise the subsequent sidebar reload will
                // surface it in the correct bucket.
                if shouldShowInFilter(item, filter: state.filter) {
                    state.items.insert(item, at: 0)
                }
                return .none

            case .saveURLFailed(let error):
                state.isSaving = false
                state.saveState = .failed
                state.errorMessage = error
                return .none

            case .importPDFSelected(let pickedURL):
                // Foreground import via `UIDocumentPicker` / SwiftUI
                // `fileImporter`. Bypasses the ingestion queue — we have the
                // main app's full memory budget and can run PDFKit + Vision
                // inline. The picked URL is inside a security-scoped
                // resource; the caller (LibraryScreen) starts/stops access
                // and copies the file into a temp scratch before dispatching
                // this action, so by the time we see the URL it's a plain
                // temp file we own.
                state.isSaving = true
                state.saveState = .extracting
                state.errorMessage = nil
                let repository = self.repository
                let pdfIngestionClient = self.pdfIngestionClient
                return .run { send in
                    // The screen copies the picked file into a UUID-named
                    // scratch subdirectory inside the temp dir so the
                    // original filename is preserved for title fallback.
                    // Clean up the whole subdir when we're done, but guard
                    // against ever removing the temp dir itself.
                    defer {
                        let parent = pickedURL.deletingLastPathComponent()
                        if parent.path != FileManager.default.temporaryDirectory.path {
                            try? FileManager.default.removeItem(at: parent)
                        } else {
                            try? FileManager.default.removeItem(at: pickedURL)
                        }
                    }
                    do {
                        let result = try await pdfIngestionClient.ingest(pickedURL)
                        let item = try await repository.createItemFromIngestion(result)
                        try? PDFArchiver.archivePDF(from: pickedURL, itemID: item.id)
                        await send(.saveURLFinished(item))
                        await send(.openItem(item))
                    } catch {
                        await send(.saveURLFailed(error.localizedDescription))
                    }
                }

            case .importWebsiteSelected(let pickedURL):
                // Foreground import via `UIDocumentPicker` / `NSOpenPanel`.
                // The screen copies the picked .zip into a UUID-named scratch
                // subdirectory before dispatching this action so we own the
                // file and security-scoped access has already been released.
                // Mirrors `.importPDFSelected` — we run inline to open the
                // site as soon as the unpack finishes.
                state.isSaving = true
                state.saveState = .extracting
                state.errorMessage = nil
                let repository = self.repository
                return .run { send in
                    defer {
                        let parent = pickedURL.deletingLastPathComponent()
                        if parent.path != FileManager.default.temporaryDirectory.path {
                            try? FileManager.default.removeItem(at: parent)
                        } else {
                            try? FileManager.default.removeItem(at: pickedURL)
                        }
                    }
                    do {
                        let item = try await WebsiteImportService.importWebsite(
                            zipURL: pickedURL,
                            repository: repository
                        )
                        await send(.saveURLFinished(item))
                        await send(.openItem(item))
                    } catch {
                        await send(.saveURLFailed(error.localizedDescription))
                    }
                }

            case .deleteItem(let id):
                // Soft delete. If we're already looking at the trash, keep the
                // row visible — it's now the current list.
                if state.filter != .recentlyDeleted {
                    state.items.removeAll { $0.id == id }
                }
                let repository = self.repository
                return .run { send in
                    do {
                        try await repository.deleteItem(id)
                        await send(.deleteFinished)
                    } catch {
                        await send(.deleteFailed(error.localizedDescription))
                    }
                }

            case .permanentlyDelete(let id):
                state.items.removeAll { $0.id == id }
                let repository = self.repository
                return .run { send in
                    do {
                        try await repository.permanentlyDelete(id)
                        AssetArchiver.deleteArchive(for: id)
                        PDFArchiver.deletePDF(for: id)
                        await send(.deleteFinished)
                    } catch {
                        await send(.deleteFailed(error.localizedDescription))
                    }
                }

            case .restoreFromTrash(let id):
                // Leaves the item visible unless we're in the trash view.
                if state.filter == .recentlyDeleted {
                    state.items.removeAll { $0.id == id }
                }
                let repository = self.repository
                return .run { send in
                    do {
                        try await repository.restoreFromTrash(id)
                        await send(.deleteFinished)
                    } catch {
                        await send(.deleteFailed(error.localizedDescription))
                    }
                }

            case .toggleStar(let id):
                guard let idx = state.items.firstIndex(where: { $0.id == id }) else {
                    return .none
                }
                let newValue = !state.items[idx].isStarred
                state.items[idx].isStarred = newValue
                // If the active filter depends on the toggled attribute,
                // drop the row so it doesn't misfile.
                if state.filter == .starred, newValue == false {
                    state.items.remove(at: idx)
                }
                let repository = self.repository
                return .run { _ in try? await repository.setStarred(id, newValue) }

            case .toggleRead(let id):
                guard let idx = state.items.firstIndex(where: { $0.id == id }) else {
                    return .none
                }
                let newValue = !state.items[idx].isRead
                state.items[idx].isRead = newValue
                switch state.filter {
                case .unread where newValue == true, .read where newValue == false:
                    state.items.remove(at: idx)
                default:
                    break
                }
                let repository = self.repository
                return .run { _ in try? await repository.setReadStatus(id, newValue) }

            case .reprocessItem(let id):
                // Mark extracting in UI immediately
                if let idx = state.items.firstIndex(where: { $0.id == id }) {
                    state.items[idx].processingState = .extracting
                }
                let repository = self.repository
                let articleSaveClient = self.articleSaveClient
                return .run { send in
                    do {
                        guard let item = try await repository.loadItem(id),
                              let source = item.sourceURL,
                              let url = URL(string: source)
                        else {
                            await send(.failed("Source URL unavailable for refresh."))
                            return
                        }

                        let refreshed = try await articleSaveClient.refresh(id, url)
                        await send(.reprocessFinished(refreshed.item))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.articleRefresh, cancelInFlight: true)

            case .deleteFailed(let error):
                state.errorMessage = error
                return .none

            case .reprocessFinished(let updatedItem):
                if let idx = state.items.firstIndex(where: { $0.id == updatedItem.id }) {
                    state.items[idx] = updatedItem
                }
                return .none

            case .deleteFinished, .openItem:
                return .none
            }
        }
    }
}

private struct TextImportRequest {
    var text: String
    var explicitTitle: String?
    var titleHint: String?
    var mode: TextImportMode
    var openAfterSave: Bool
}

private func runTextImport(
    _ request: TextImportRequest,
    repository: StowerRepository,
    textIngestionClient: TextIngestionClient
) -> EffectOf<LibraryFeature> {
    .run { send in
        do {
            let result = try await textIngestionClient.ingest(
                request.text,
                request.explicitTitle,
                request.titleHint,
                request.mode
            )
            let item = try await repository.createItemFromIngestion(result)
            await send(.saveURLFinished(item))
            if request.openAfterSave {
                await send(.openItem(item))
            }
        } catch {
            await send(.saveURLFailed(error.localizedDescription))
        }
    }
}

private func normalizeSourceURL(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // If the user typed a scheme (or pasted one), lowercase it so we don't
    // end up with "Https://…" from iOS autocapitalization. URL schemes are
    // case-insensitive per RFC 3986, but `URL(string:)` and third-party
    // parsers have a habit of being picky about the canonical form.
    if let schemeRange = trimmed.range(of: "://") {
        let scheme = trimmed[trimmed.startIndex..<schemeRange.lowerBound].lowercased()
        let rest = trimmed[schemeRange.lowerBound...]
        return scheme + rest
    }

    if trimmed.contains(".") {
        return "https://\(trimmed)"
    }
    return nil
}

/// Does this item belong in the currently displayed filter? Used to decide
/// whether newly-saved items should be pre-inserted at the top of the list.
private func shouldShowInFilter(_ item: SavedItem, filter: LibraryFilter) -> Bool {
    switch filter {
    case .all:
        return item.deletedAt == nil
    case .unread:
        return item.deletedAt == nil && !item.isRead
    case .read:
        return item.deletedAt == nil && item.isRead
    case .starred:
        return item.deletedAt == nil && item.isStarred
    case .untagged:
        return item.deletedAt == nil && item.tagIDs.isEmpty
    case .recentlyDeleted:
        return item.deletedAt != nil
    case let .tag(id):
        return item.deletedAt == nil && item.tagIDs.contains(id)
    }
}
