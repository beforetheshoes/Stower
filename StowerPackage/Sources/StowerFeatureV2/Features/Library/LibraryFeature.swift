import ComposableArchitecture
import Foundation

@Reducer
public struct LibraryFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        // swiftlint:disable:next prefer_let_over_var
        public var items: [SavedItem] = []
        public var query = ""
        public var sourceURL = ""
        public var isLoading = false
        public var isSaving = false
        public var saveState: ProcessingState = .queued
        public var errorMessage: String?
        /// Which list is currently being viewed. Drives `fetchLibrary(_:)`.
        public var filter: LibraryFilter = .all
        /// All tags known to the repository — drives the "Tags" submenu in the
        /// library row context menu. Refreshed lazily via observeLibraryChanges.
        public var availableTags: [Tag] = [] // swiftlint:disable:this prefer_let_over_var

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
            guard !query.isEmpty else {
                return items
            }
            return items.filter { item in
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
        }

        public init() {}
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case response([SavedItem])
        case failed(String)
        case queryChanged(String)
        case filterChanged(LibraryFilter)
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
        case saveURLFinished(SavedItem)
        case saveURLFailed(String)
        case importPDFSelected(URL)

        // Tag assignment
        case reloadTags
        case tagsLoaded([Tag])
        case toggleTagOnItem(UUID, UUID)
        case observedChange
    }

    private enum CancelID: Hashable {
        case observeChanges
    }

    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.urlIngestionClient)
    var ingestionClient
    @Dependency(\.pdfIngestionClient)
    var pdfIngestionClient

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
                // Background ping: refresh tag list only. Don't re-fetch items
                // because that would clobber scroll position and any pending
                // optimistic mutations.
                return .send(.reloadTags)

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

            case .sourceURLChanged(let value):
                state.sourceURL = value
                if state.saveState == .failed {
                    state.saveState = .queued
                }
                return .none

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
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                return .run { send in
                    do {
                        let result = try await ingestionClient.ingest(url)
                        let item = try await repository.createItemFromIngestion(result)

                        // Archive all external assets for offline WebView rendering.
                        if result.renderFormat == .webView,
                           !result.sourceHTML.isEmpty,
                           let source = result.sourceURL,
                           let baseURL = URL(string: source) {
                            await AssetArchiver.archiveAssets(
                                html: result.sourceHTML,
                                baseURL: baseURL,
                                itemID: item.id
                            )
                        }

                        await send(.saveURLFinished(item))
                        await send(.openItem(item))
                    } catch {
                        await send(.saveURLFailed(error.localizedDescription))
                    }
                }

            case .saveURLFinished(let item):
                state.isSaving = false
                state.saveState = .ready
                state.sourceURL = ""
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
                let ingestionClient = self.ingestionClient
                return .run { send in
                    do {
                        guard let item = try await repository.loadItem(id),
                              let source = item.sourceURL,
                              let url = URL(string: source)
                        else {
                            await send(.failed("Source URL unavailable for refresh."))
                            return
                        }

                        let result = try await ingestionClient.ingest(url)
                        guard let updatedItem = try await repository.updateItemFromIngestion(id, result) else {
                            await send(.failed("This item no longer exists."))
                            return
                        }

                        // Re-archive assets for offline WebView rendering.
                        if result.renderFormat == .webView,
                           !result.sourceHTML.isEmpty,
                           let source = result.sourceURL,
                           let baseURL = URL(string: source) {
                            AssetArchiver.deleteArchive(for: id)
                            await AssetArchiver.archiveAssets(
                                html: result.sourceHTML,
                                baseURL: baseURL,
                                itemID: id
                            )
                        }

                        await send(.reprocessFinished(updatedItem))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

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
