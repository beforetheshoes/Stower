import ComposableArchitecture
import Foundation
import SQLiteData

@Reducer
public struct LibraryFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        /// Database-observed rows, tags, and storage state for the current
        /// filter, query, and sort. Every write anywhere in the app shows up
        /// here through observation; nothing reloads the list by hand.
        @Fetch public var library = LibraryRequest.Value()
        /// False until the first observation has delivered a value, so the
        /// empty state never flashes before the rows arrive.
        public var hasLoaded = false
        public var query = ""
        public var sourceURL = ""
        public var isSaving = false
        public var saveState: ProcessingState = .queued
        /// Incremented each time a URL is handed to the ingestion queue; the
        /// Add URL sheet dismisses when it changes.
        public var queuedSaveCount = 0
        public var errorMessage: String?
        /// Which list is currently being viewed. Part of the observed query.
        public var filter: LibraryFilter = .unread
        public var displayStyle: LibraryDisplayStyle = .compact
        public var sortOrder: LibrarySortOrder = .newestFirst
        /// The item the reader is currently showing. Drives list selection
        /// on Mac and iPad; kept in sync by the app reducer.
        public var openItemID: UUID?
        /// Non-nil when the user is creating a new tag inline from the tag submenu.
        public var inlineTagCreation: InlineTagCreation?
        /// Draft for the in-app text/markdown composer.
        public var textImportDraft: TextImportDraft?

        public var items: [SavedItem] { library.items }
        public var availableTags: [Tag] { library.tags }
        public var storageInfoByID: [UUID: ItemStorageInfo] { library.storageInfoByID }

        var request: LibraryRequest {
            LibraryRequest(
                filter: filter,
                query: query,
                oldestFirst: sortOrder == .oldestFirst
            )
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
        case libraryLoaded
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
        /// List selection changed (Mac and iPad). Nil is a deselection and
        /// leaves the reader alone.
        case rowSelected(UUID?)
        case reprocessItem(UUID)
        case reprocessFinished(SavedItem)
        case sourceURLChanged(String)
        case saveURLTapped
        case saveExternalURL(URL)
        /// A URL was placed in the ingestion queue. The app reducer drains
        /// the queue in response.
        case urlQueued(URL)
        case cancelURLSaveTapped
        case saveURLFinished(SavedItem)
        case saveURLFailed(String)
        case importPDFSelected(URL)
        case importWebsiteSelected(URL)

        // Download management (offload)
        case setPinned(UUID, Bool)
        case removeDownload(UUID)
        case downloadNow(UUID)
        case addTextTapped
        case textImportDismissed
        case textImportTitleChanged(String)
        case textImportTextChanged(String)
        case textImportModeChanged(TextImportMode)
        case saveTextImportTapped
        case importTextResolved(String, String?, TextImportMode)

        // Tag assignment
        case toggleTagOnItem(UUID, UUID)

        // Inline tag creation
        case inlineCreateTagTapped(UUID)
        case inlineCreateTagNameChanged(String)
        case inlineCreateTagColorChanged(String)
        case inlineCreateTagConfirmed
        case inlineCreateTagDismissed
        case inlineTagCreated(Tag, UUID)
    }

    private enum CancelID: Hashable {
        case load
        case searchDebounce
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
    @Dependency(\.itemStorageClient)
    var itemStorageClient
    @Dependency(\.cloudAssetClient)
    var cloudAssetClient
    @Dependency(\.continuousClock)
    var clock

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return loadLibrary(state)

            case .libraryLoaded:
                state.hasLoaded = true
                return .none

            case .failed(let error):
                state.errorMessage = error
                return .none

            case .queryChanged(let value):
                guard value != state.query else { return .none }
                state.query = value
                // Typing re-runs the SQL search; a short debounce keeps the
                // observation from being torn down on every keystroke.
                let clock = self.clock
                let request = state.request
                let library = state.$library
                return .run { send in
                    try await clock.sleep(for: .milliseconds(150))
                    try await library.load(request, animation: .default)
                    await send(.libraryLoaded)
                }
                .cancellable(id: CancelID.searchDebounce, cancelInFlight: true)

            case .filterChanged(let filter):
                guard filter != state.filter else { return .none }
                state.filter = filter
                state.query = ""
                return loadLibrary(state)

            case .rowSelected(let id):
                guard let id, id != state.openItemID,
                      let item = state.items.first(where: { $0.id == id })
                else { return .none }
                return .send(.openItem(item))

            case .displayStyleChanged(let displayStyle):
                state.displayStyle = displayStyle
                return .none

            case .sortOrderChanged(let sortOrder):
                guard sortOrder != state.sortOrder else { return .none }
                state.sortOrder = sortOrder
                return loadLibrary(state)

            case let .toggleTagOnItem(itemID, tagID):
                guard let item = state.items.first(where: { $0.id == itemID }) else {
                    return .none
                }
                let shouldAdd = !item.tagIDs.contains(tagID)
                let repository = self.repository
                return .run { send in
                    do {
                        if shouldAdd {
                            try await repository.addTag(itemID, tagID)
                        } else {
                            try await repository.removeTag(itemID, tagID)
                        }
                    } catch {
                        await send(.failed(error.localizedDescription))
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
                    do {
                        let tag = try await repository.createTag(name, colorHex)
                        try await repository.addTag(itemID, tag.id)
                        await send(.inlineTagCreated(tag, itemID))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .inlineTagCreated:
                // Observation delivers the new tag and assignment.
                return .none

            case let .setPinned(id, isPinned):
                let itemStorageClient = self.itemStorageClient
                return .run { _ in
                    try? await itemStorageClient.setPinned(id, isPinned)
                }

            case .removeDownload(let id):
                let repository = self.repository
                return .run { send in
                    do {
                        try await StorageOffloadService.offload(itemID: id, repository: repository)
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .downloadNow(let id):
                let repository = self.repository
                return .run { send in
                    do {
                        try? await repository.updateLocalContentStatus(id, "downloading", nil)
                        try await CloudAssetService.restore(itemID: id, repository: repository)
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

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
                return enqueueURL(url)

            case .saveExternalURL(let url):
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    state.errorMessage = "The browser shared an invalid URL."
                    state.saveState = .failed
                    return .none
                }
                state.errorMessage = nil
                return enqueueURL(url)

            case .urlQueued:
                // Saving is asynchronous: the sheet closes, the field clears,
                // and the row arrives through observation once fetched.
                state.isSaving = false
                state.saveState = .queued
                state.sourceURL = ""
                state.queuedSaveCount += 1
                return .none

            case .cancelURLSaveTapped:
                state.isSaving = false
                state.saveState = .queued
                state.errorMessage = nil
                return .none

            case .saveURLFinished(let item):
                state.isSaving = false
                state.saveState = item.processingState
                state.sourceURL = ""
                state.textImportDraft = nil
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
                // inline. The caller copies the picked file into a temp
                // scratch we own before dispatching this action.
                state.isSaving = true
                state.saveState = .extracting
                state.errorMessage = nil
                let repository = self.repository
                let pdfIngestionClient = self.pdfIngestionClient
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
                        let result = try await pdfIngestionClient.ingest(pickedURL)
                        let item = try await repository.createItemFromIngestion(result)
                        try? PDFArchiver.archivePDF(from: pickedURL, itemID: item.id)
                        if let payload = try? AssetJobPayload(
                            itemID: item.id,
                            kind: .pdf,
                            originalFilename: pickedURL.lastPathComponent
                        ).encoded() {
                            try? await repository.enqueueIngestionJob(.uploadAsset, payload)
                        }
                        await send(.saveURLFinished(item))
                        await send(.openItem(item))
                    } catch {
                        await send(.saveURLFailed(error.localizedDescription))
                    }
                }

            case .importWebsiteSelected(let pickedURL):
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
                let repository = self.repository
                let itemStorageClient = self.itemStorageClient
                let cloudAssetClient = self.cloudAssetClient
                return .run { send in
                    do {
                        // Capture asset record names before the delete removes
                        // the manifest rows, then clean up the CloudKit copies
                        // best-effort — a failure here only leaves an orphaned
                        // record in the user's own private zone.
                        let manifests = (try? await itemStorageClient.manifests([id])) ?? []
                        try await repository.permanentlyDelete(id)
                        AssetArchiver.deleteArchive(for: id)
                        PDFArchiver.deletePDF(for: id)
                        for manifest in manifests {
                            try? await cloudAssetClient.delete(manifest.recordName)
                        }
                        await send(.deleteFinished)
                    } catch {
                        await send(.deleteFailed(error.localizedDescription))
                    }
                }

            case .restoreFromTrash(let id):
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
                guard let item = state.items.first(where: { $0.id == id }) else {
                    return .none
                }
                let newValue = !item.isStarred
                let repository = self.repository
                return .run { send in
                    do {
                        try await repository.setStarred(id, newValue)
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .toggleRead(let id):
                guard let item = state.items.first(where: { $0.id == id }) else {
                    return .none
                }
                let newValue = !item.isRead
                let repository = self.repository
                return .run { send in
                    do {
                        try await repository.setReadStatus(id, newValue)
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .reprocessItem(let id):
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
                        // The row shows its spinner from this status until the
                        // refresh writes the new content.
                        try? await repository.updateLocalContentStatus(id, "downloading", nil)
                        let refreshed = try await articleSaveClient.refresh(id, url)
                        await send(.reprocessFinished(refreshed.item))
                    } catch is CancellationError {
                        return
                    } catch {
                        try? await repository.updateLocalContentStatus(id, "failed", error.localizedDescription)
                        await send(.failed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.articleRefresh, cancelInFlight: true)

            case .deleteFailed(let error):
                state.errorMessage = error
                return .none

            case .reprocessFinished, .deleteFinished, .openItem:
                return .none
            }
        }
    }

    /// Hands a URL to the ingestion queue. The fetch itself runs in the
    /// background (the app reducer drains the queue), so the user is never
    /// held in a modal while a page loads.
    private func enqueueURL(_ url: URL) -> EffectOf<Self> {
        let repository = self.repository
        return .run { send in
            do {
                try await repository.enqueueIngestionJob(.url, url.absoluteString)
                await send(.urlQueued(url))
            } catch {
                await send(.saveURLFailed(error.localizedDescription))
            }
        }
    }

    /// Points the observed query at the current filter, sort, and search
    /// text. Rows animate into their new positions when the query changes.
    private func loadLibrary(_ state: State) -> EffectOf<Self> {
        let request = state.request
        let library = state.$library
        return .run { send in
            do {
                try await library.load(request, animation: .default)
                await send(.libraryLoaded)
            } catch {
                await send(.failed(error.localizedDescription))
            }
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)
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
