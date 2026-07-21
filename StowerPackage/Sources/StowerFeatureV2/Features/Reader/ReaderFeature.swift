import ComposableArchitecture
import Foundation

@Reducer
public struct ReaderFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var itemID: UUID
        public var item: SavedItem?
        public var document: ReaderDocument?
        public var sourceHTML: String?
        public var appearance: ReaderAppearanceSettings
        var viewportWidth: Double?
        var currentBlockIndex: Int?
        var isChromeHidden = false
        var speech = ReaderSpeechFeature.State()
        var ai = ReaderAIFeature.State()
        public var isLoading = false
        public var errorMessage: String?
        @Presents public var inlineEmbedURL: InlineEmbedFeature.State?
        public var textEditor: TextEditorState?

        /// Whether the user has manually overridden the render mode.
        public var renderModeOverride: RenderFormat?

        /// The render format the reader should use right now.
        ///
        /// Priority:
        /// 1. Explicit user override (`switchRenderMode` button)
        /// 2. The item's own `renderFormat` as detected during ingestion —
        ///    this is what makes SVG-rich articles render in the archive/
        ///    WebView path instead of falling back to stripped structured
        ///    text. Falling back to `.structuredV1` here (as was previously
        ///    the case) silently broke every interactive-SVG page.
        /// 3. `.structuredV1` if the item hasn't loaded yet.
        public var effectiveRenderFormat: RenderFormat {
            if let renderModeOverride {
                return renderModeOverride
            }
            if let item {
                return item.renderFormat
            }
            return .structuredV1
        }

        /// Whether the original article was detected as having interactive content.
        public var hasInteractiveContent: Bool {
            item?.renderFormat == .webView
        }

        public var canEditTextSource: Bool {
            guard let item else { return false }
            return item.sourceURL == nil && item.renderFormat != .pdf
        }

        var lineWidthPolicy: ReaderLineWidthPolicy {
            ReaderLineWidthPolicy(viewportWidth: viewportWidth)
        }

        public var totalProgressUnitCount: Int? {
            if let document, !document.blocks.isEmpty {
                return document.blocks.count
            }
            return item?.progressUnitCount
        }

        public var readingProgress: ReadingProgressSnapshot? {
            guard effectiveRenderFormat != .webView,
                  let totalProgressUnitCount,
                  let currentBlockIndex
            else {
                return nil
            }
            return ReadingProgressSnapshot(
                currentUnitIndex: currentBlockIndex,
                totalUnitCount: totalProgressUnitCount
            )
        }

        /// Initialize with a full SavedItem (preferred — instant header render).
        public init(item: SavedItem, appearance: ReaderAppearanceSettings = .init()) {
            self.itemID = item.id
            self.item = item
            self.appearance = appearance
            self.currentBlockIndex = item.lastReadBlockIndex ?? 0
        }

        /// Initialize with just an ID (fallback — requires DB load).
        public init(itemID: UUID, appearance: ReaderAppearanceSettings = .init()) {
            self.itemID = itemID
            self.appearance = appearance
        }
    }

    public struct TextEditorState: Equatable, Sendable {
        public var title: String
        public var text: String
        public var mode: TextImportMode
        public var isSaving = false
        public var errorMessage: String?

        public init(
            title: String,
            text: String,
            mode: TextImportMode,
            isSaving: Bool = false,
            errorMessage: String? = nil
        ) {
            self.title = title
            self.text = text
            self.mode = mode
            self.isSaving = isSaving
            self.errorMessage = errorMessage
        }
    }

    public enum Action: Equatable {
        case load
        case loaded(SavedItem?, ReaderDocument?, String?)
        case failed(String)

        case speech(ReaderSpeechFeature.Action)
        case ai(ReaderAIFeature.Action)

        case fontSizeChanged(Double)
        case fontStyleChanged(ReaderFontStyle)
        case lineSpacingChanged(Double)
        case justificationChanged(ReaderJustification)
        case backgroundChanged(ReaderBackground)
        case primaryAccentChanged(FlexokiHue)
        case secondaryAccentChanged(FlexokiHue)
        case viewportWidthChanged(Double)
        case lineWidthChanged(Double)
        case saveAppearance
        case saveAppearanceFinished
        case saveAppearanceFailed(String)

        case retryExtractionTapped
        case retryFinished(SavedItem?)
        case editTextTapped
        case editableTextLoaded(EditableTextSource)
        case editableTextFailed(String)
        case textEditorDismissed
        case textEditorTitleChanged(String)
        case textEditorTextChanged(String)
        case textEditorModeChanged(TextImportMode)
        case saveTextEditTapped
        case textEditSaved(SavedItem, ReaderDocument)
        case textEditFailed(String)
        case openInlineWebEmbed(String)
        case inlineEmbedURL(PresentationAction<InlineEmbedFeature.Action>)
        case switchRenderMode(RenderFormat)
        case loadDisplayPreference
        case displayPreferenceLoaded(RenderFormat?)

        /// Emitted by the reader view when the top-visible block changes.
        /// Triggers a debounced save of the reading position.
        case scrollProgressChanged(Int)
        case saveReadingProgress(Int)
        case contentAreaTapped

        /// User tapped the toolbar mark-read/unread button.
        case toggleReadTapped

        /// Explicitly completes the article and asks the parent to leave the reader.
        case doneTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case done(itemID: UUID, wasUnread: Bool)
        }
    }

    private enum CancelID {
        case appearanceSave
        case readingProgressSave
        case progressPoll
        case articleRefresh
    }

    @Dependency(\.stowerRepository)
    var repository
    @Dependency(\.urlIngestionClient)
    var ingestionClient
    @Dependency(\.articleSaveClient)
    var articleSaveClient
    @Dependency(\.continuousClock)
    var continuousClock
    @Dependency(\.readerProgressClient)
    var readerProgressClient
    @Dependency(\.cloudSyncClient)
    var cloudSyncClient
    @Dependency(\.readerDisplayPreferenceClient)
    var readerDisplayPreferenceClient

    @Dependency(\.textIngestionClient)
    var textIngestionClient
    @Dependency(\.date)
    var date

    public var body: some ReducerOf<Self> {
        Scope(\.speech, action: \.speech) {
            ReaderSpeechFeature()
        }
        Scope(\.ai, action: \.ai) {
            ReaderAIFeature()
        }
        Reduce { state, action in
            switch action {
            case .load:
                // Fast path: if the document is already loaded for this item,
                // skip the async work entirely. This prevents the expensive
                // JSON decode and SwiftUI view-tree rebuild when the view
                // reappears (e.g. returning from a pushed embed screen) and
                // makes re-opening the same article feel instant.
                if state.document != nil,
                   state.item?.id == state.itemID {
                    state.isLoading = false
                    state.currentBlockIndex = state.item?.lastReadBlockIndex ?? 0
                    return .merge(
                        .send(.speech(.loadPreferences)),
                        .send(.loadDisplayPreference)
                    )
                }

                state.isLoading = true
                state.errorMessage = nil
                let repository = self.repository
                let needsItem = state.item == nil
                return .merge(
                    .send(.speech(.loadPreferences)),
                    .run { [id = state.itemID] send in
                        do {
                            // Only load item from DB if not already provided
                            let loadedItem: SavedItem? = needsItem
                                ? try await repository.loadItem(id)
                                : nil
                            async let document = repository.loadReaderDocument(id)
                            async let sourceHTML = repository.loadSourceHTML(id)
                            let loadedDoc = try await document
                            let loadedHTML = try await sourceHTML
                            await send(.loaded(loadedItem, loadedDoc, loadedHTML))
                        } catch {
                            await send(.failed(error.localizedDescription))
                        }
                    }
                )

            case let .loaded(item, document, sourceHTML):
                state.isLoading = false
                if let item { state.item = item }
                state.document = document
                state.sourceHTML = sourceHTML
                state.currentBlockIndex = state.item?.lastReadBlockIndex ?? 0
                return .merge(
                    archiveIfNeeded(item: state.item, sourceHTML: sourceHTML),
                    startProgressPollingEffect(),
                    .send(.ai(.appeared(itemID: state.itemID))),
                    .send(.loadDisplayPreference)
                )

            case .failed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none

            case .editTextTapped:
                guard state.canEditTextSource else { return .none }
                let repository = self.repository
                let itemID = state.itemID
                return .run { send in
                    do {
                        guard let source = try await repository.loadEditableTextSource(itemID) else {
                            await send(.editableTextFailed("This item can't be edited."))
                            return
                        }
                        await send(.editableTextLoaded(source))
                    } catch {
                        await send(.editableTextFailed(error.localizedDescription))
                    }
                }

            case .editableTextLoaded(let source):
                state.textEditor = TextEditorState(
                    title: source.title,
                    text: source.text,
                    mode: source.mode
                )
                return .none

            case .editableTextFailed(let message):
                state.errorMessage = message
                return .none

            case .textEditorDismissed:
                state.textEditor = nil
                return .none

            case .textEditorTitleChanged(let title):
                state.textEditor?.title = title
                state.textEditor?.errorMessage = nil
                return .none

            case .textEditorTextChanged(let text):
                state.textEditor?.text = text
                state.textEditor?.errorMessage = nil
                return .none

            case .textEditorModeChanged(let mode):
                state.textEditor?.mode = mode
                state.textEditor?.errorMessage = nil
                return .none

            case .saveTextEditTapped:
                guard let editor = state.textEditor else { return .none }
                let trimmed = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.textEditor?.errorMessage = "Enter some text or markdown."
                    return .none
                }
                state.textEditor?.isSaving = true
                state.textEditor?.errorMessage = nil
                let repository = self.repository
                let textIngestionClient = self.textIngestionClient
                let itemID = state.itemID
                return .run { send in
                    do {
                        let result = try await textIngestionClient.ingest(
                            editor.text,
                            editor.title,
                            nil,
                            editor.mode
                        )
                        guard let item = try await repository.saveEditedTextSource(itemID, result) else {
                            await send(.textEditFailed("This item no longer exists."))
                            return
                        }
                        await send(.textEditSaved(item, result.document))
                    } catch {
                        await send(.textEditFailed(error.localizedDescription))
                    }
                }

            case let .textEditSaved(item, document):
                state.item = item
                state.document = document
                state.sourceHTML = nil
                state.textEditor = nil
                return .none

            case .textEditFailed(let message):
                state.textEditor?.isSaving = false
                state.textEditor?.errorMessage = message
                return .none

            // Appearance is now passed in via init — no async loading needed.

            case .fontSizeChanged(let value):
                state.appearance.fontSize = value
                state.appearance.clamp()
                return .send(.saveAppearance)

            case .fontStyleChanged(let value):
                state.appearance.fontStyle = value
                return .send(.saveAppearance)

            case .lineSpacingChanged(let value):
                state.appearance.lineSpacing = value
                state.appearance.clamp()
                return .send(.saveAppearance)

            case .justificationChanged(let value):
                state.appearance.justification = value
                return .send(.saveAppearance)

            case .backgroundChanged(let value):
                state.appearance.background = value
                return .send(.saveAppearance)

            case .primaryAccentChanged(let value):
                state.appearance.primaryAccent = value
                return .send(.saveAppearance)

            case .secondaryAccentChanged(let value):
                state.appearance.secondaryAccent = value
                return .send(.saveAppearance)

            case .viewportWidthChanged(let width):
                guard width.isFinite, width > 0 else {
                    state.viewportWidth = nil
                    return .none
                }
                state.viewportWidth = width
                return .none

            case .lineWidthChanged(let value):
                state.appearance.lineWidth = state.lineWidthPolicy.clamped(value)
                return .send(.saveAppearance)

            case .saveAppearance:
                let repository = self.repository
                let clock = self.continuousClock
                return .run { [appearance = state.appearance] send in
                    do {
                        try await clock.sleep(for: .milliseconds(150))
                        try await repository.saveReaderAppearanceSettings(appearance.clamped())
                        await send(.saveAppearanceFinished)
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.saveAppearanceFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.appearanceSave, cancelInFlight: true)

            case .saveAppearanceFinished:
                return .none

            case .saveAppearanceFailed(let error):
                state.errorMessage = error
                return .none

            case .retryExtractionTapped:
                // Items without a source URL come from one of two paths:
                // imported websites (zip bytes live in the archive sync
                // table) or text/markdown (raw source in the text sync
                // table). The item's renderFormat only survives in the
                // LOCAL content table, which doesn't exist on the device
                // that synced the item down — so we can't use it as a
                // discriminator here. Instead, peek at the archive sync
                // table first: if a row exists for this ID, treat it as a
                // website regardless of what renderFormat the domain model
                // is currently reporting.
                if state.item?.sourceURL == nil {
                    state.isLoading = true
                    state.errorMessage = nil
                    let repository = self.repository
                    let textIngestionClient = self.textIngestionClient
                    let cloudSyncClient = self.cloudSyncClient
                    let date = self.date
                    return .run { [id = state.itemID] send in
                        do {
                            try? await cloudSyncClient.sendChanges()

                            if let archive = try await repository.loadWebsiteArchive(id) {
                                try await WebsiteImportService.hydrateWebsite(
                                    itemID: id,
                                    archive: archive,
                                    repository: repository
                                )
                                let item = try await repository.loadItem(id)
                                await send(.retryFinished(item))
                                return
                            }

                            // Fall back to the text/markdown hydration path.
                            _ = try await repository.hydrateTextItemsFromSyncedContent()
                            var hydratedTextItem = false
                            while let job = try await repository.claimNextIngestionJobOfKind(
                                .hydrateText,
                                date.now
                            ) {
                                do {
                                    let data = Data(job.payload.utf8)
                                    let payload = try JSONDecoder().decode(TextHydrationPayload.self, from: data)
                                    let mode = payload.rawSourceMode
                                        .flatMap(TextImportMode.init(rawValue:))
                                        ?? .auto
                                    let result = try await textIngestionClient.ingest(
                                        payload.rawSourceText,
                                        payload.title,
                                        nil,
                                        mode
                                    )
                                    try await repository.hydrateItemContent(payload.itemID, result)
                                    try await repository.completeIngestionJob(job.id, date.now)
                                    hydratedTextItem = hydratedTextItem || payload.itemID == id
                                } catch {
                                    try await repository.failIngestionJob(
                                        job.id,
                                        error.localizedDescription,
                                        date.now
                                    )
                                }
                            }

                            if !hydratedTextItem {
                                await send(.failed(
                                    "The full content hasn't finished syncing from iCloud yet. Try again in a moment."
                                ))
                                return
                            }
                            let item = try await repository.loadItem(id)
                            await send(.retryFinished(item))
                        } catch let error as WebsiteImportService.ImportError {
                            if case .incompleteAsset = error {
                                await send(.failed(
                                    "Still downloading the website archive from iCloud. Try again in a moment."
                                ))
                            } else {
                                await send(.failed(error.localizedDescription))
                            }
                        } catch {
                            await send(.failed(error.localizedDescription))
                        }
                    }
                }

                guard let source = state.item?.sourceURL,
                      let url = URL(string: source)
                else {
                    state.errorMessage = "Source URL unavailable for refresh."
                    return .none
                }

                state.isLoading = true
                let articleSaveClient = self.articleSaveClient
                return .run { [id = state.itemID] send in
                    do {
                        let refreshed = try await articleSaveClient.refresh(id, url)
                        await send(.retryFinished(refreshed.item))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.articleRefresh, cancelInFlight: true)

            case .retryFinished(let item):
                if let item {
                    state.item = item
                    return .send(.load)
                } else {
                    state.isLoading = false
                    state.errorMessage = "Unable to refresh this item."
                    return .none
                }

            case .openInlineWebEmbed(let urlString):
                guard let url = URL(string: urlString) else {
                    return .none
                }
                state.inlineEmbedURL = InlineEmbedFeature.State(url: url)
                return .none

            case .inlineEmbedURL:
                return .none

            case .switchRenderMode(let format):
                state.renderModeOverride = format
                let preferenceClient = self.readerDisplayPreferenceClient
                let host = state.item?.sourceURL
                    .flatMap(URL.init(string:))?
                    .host
                let savePreference: EffectOf<Self> = host.map { host in
                    .run { _ in await preferenceClient.save(host, format) }
                } ?? .none
                // When the user flips to web view on an article that
                // wasn't originally ingested as `.webView`, the external
                // assets (CSS, JS, images, SVGs) haven't been archived
                // yet. Kick off archiving now so the web view works
                // offline after this first switch.
                if format == .webView {
                    return .merge(
                        archiveForWebView(item: state.item, sourceHTML: state.sourceHTML),
                        savePreference
                    )
                }
                return savePreference

            case .loadDisplayPreference:
                guard let host = state.item?.sourceURL
                    .flatMap(URL.init(string:))?
                    .host
                else { return .none }
                let preferenceClient = self.readerDisplayPreferenceClient
                return .run { send in
                    await send(.displayPreferenceLoaded(await preferenceClient.load(host)))
                }

            case .displayPreferenceLoaded(let format):
                if state.renderModeOverride == nil {
                    state.renderModeOverride = format
                }
                return .none

            case .scrollProgressChanged(let blockIndex):
                // Update local state immediately; debounce the DB write.
                // Block index 0 means "at the top" — don't persist it (treat
                // as "no restore state") so new opens don't get a false restore.
                guard blockIndex >= 0 else { return .none }
                state.currentBlockIndex = blockIndex
                state.item?.lastReadBlockIndex = blockIndex > 0 ? blockIndex : nil

                if blockIndex == 0 {
                    return .cancel(id: CancelID.readingProgressSave)
                }
                let clock = self.continuousClock
                let saveEffect: EffectOf<Self> = .run { send in
                    try? await clock.sleep(for: .seconds(1))
                    await send(.saveReadingProgress(blockIndex), animation: nil)
                }
                .cancellable(id: CancelID.readingProgressSave, cancelInFlight: true)
                return saveEffect

            case .saveReadingProgress(let blockIndex):
                let repository = self.repository
                return .run { [id = state.itemID] _ in
                    try? await repository.saveReadingProgress(id, blockIndex)
                }

            case .contentAreaTapped:
                state.isChromeHidden.toggle()
                return .none

            case .toggleReadTapped:
                guard var item = state.item else { return .none }
                let newValue = !item.isRead
                item.isRead = newValue
                state.item = item
                let repo = self.repository
                let id = state.itemID
                return .run { _ in try? await repo.setReadStatus(id, newValue) }

            case .doneTapped:
                let wasUnread = state.item?.isRead == false
                state.item?.isRead = true
                let repository = self.repository
                let itemID = state.itemID
                return .run { send in
                    do {
                        if wasUnread {
                            try await repository.setReadStatus(itemID, true)
                        }
                        await send(.delegate(.done(itemID: itemID, wasUnread: wasUnread)))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case .delegate:
                return .none

            case .speech:
                return .none

            case .ai:
                return .none
            }
        }
        .ifLet(\.$inlineEmbedURL, action: \.inlineEmbedURL) {
            InlineEmbedFeature()
        }
    }

    /// Triggers asset archiving if the article is a webView format but has no local archive.
    /// Called on initial load — only fires for articles ingested as `.webView` to avoid
    /// wastefully downloading assets for articles the user reads in structured view.
    /// For manual switches to web view, `archiveForWebView` is called directly.
    private func archiveIfNeeded(item: SavedItem?, sourceHTML: String?) -> EffectOf<Self> {
        guard let item, item.renderFormat == .webView,
              let html = sourceHTML, !html.isEmpty,
              !AssetArchiver.archiveExists(for: item.id),
              let source = item.sourceURL,
              let baseURL = URL(string: source) else {
            return .none
        }
        let itemID = item.id
        return .run { _ in
            await AssetArchiver.archiveAssets(
                html: html,
                baseURL: baseURL,
                itemID: itemID
            )
        }
    }

    /// Archives assets for any article the user manually switches to web view,
    /// regardless of its original `renderFormat`. Unlike `archiveIfNeeded`
    /// (which only fires for `.webView`-ingested articles on load), this has
    /// no format gate — so SVG-rich or interactive pages that were ingested as
    /// `.structuredV1` still get their CSS/JS/images downloaded once the user
    /// flips the switch. No-ops if an archive already exists.
    private func archiveForWebView(item: SavedItem?, sourceHTML: String?) -> EffectOf<Self> {
        guard let item,
              let html = sourceHTML, !html.isEmpty,
              !AssetArchiver.archiveExists(for: item.id),
              let source = item.sourceURL,
              let baseURL = URL(string: source) else {
            return .none
        }
        let itemID = item.id
        return .run { _ in
            await AssetArchiver.archiveAssets(
                html: html,
                baseURL: baseURL,
                itemID: itemID
            )
        }
    }

    /// Polls the currently registered reader `WebPage` every 1.5 seconds for
    /// the topmost visible block index and emits `scrollProgressChanged`
    /// actions when it changes. Runs as a child effect so `ifLet` cancels it
    /// atomically with presentation dismissal — unlike the previous manual
    /// `Task` inside `ReaderWebView`, which kept firing during the window
    /// between `navigationDestination`'s state nil-ification and the view's
    /// `.onDisappear`, and tripped a noisy TCA runtime warning on every pop.
    private func startProgressPollingEffect() -> EffectOf<Self> {
        let client = self.readerProgressClient
        let clock = self.continuousClock
        return .run { send in
            var lastReported: Int?
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1.5))
                if Task.isCancelled {
                    return
                }
                guard let top = await client.topBlockIndex() else { continue }
                if Task.isCancelled {
                    return
                }
                if top != lastReported {
                    lastReported = top
                    await send(.scrollProgressChanged(top), animation: nil)
                }
            }
        }
        .cancellable(id: CancelID.progressPoll, cancelInFlight: true)
    }
}

@Reducer
public struct InlineEmbedFeature {
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var url: URL

        public init(url: URL) {
            self.url = url
        }
    }

    public enum Action: Equatable {
        case close
    }

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .close:
                return .none
            }
        }
    }
}
