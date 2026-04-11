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
        var speech = ReaderSpeechFeature.State()
        public var isLoading = false
        public var errorMessage: String?
        @Presents public var inlineEmbedURL: InlineEmbedFeature.State?

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
            if let renderModeOverride { return renderModeOverride }
            if let item { return item.renderFormat }
            return .structuredV1
        }

        /// Whether the original article was detected as having interactive content.
        public var hasInteractiveContent: Bool {
            item?.renderFormat == .webView
        }

        /// Initialize with a full SavedItem (preferred — instant header render).
        public init(item: SavedItem, appearance: ReaderAppearanceSettings = .init()) {
            self.itemID = item.id
            self.item = item
            self.appearance = appearance
        }

        /// Initialize with just an ID (fallback — requires DB load).
        public init(itemID: UUID, appearance: ReaderAppearanceSettings = .init()) {
            self.itemID = itemID
            self.appearance = appearance
        }
    }

    public enum Action: Equatable {
        case load
        case loaded(SavedItem?, ReaderDocument?, String?)
        case failed(String)

        case speech(ReaderSpeechFeature.Action)

        case fontSizeChanged(Double)
        case fontStyleChanged(ReaderFontStyle)
        case lineSpacingChanged(Double)
        case justificationChanged(ReaderJustification)
        case themeChanged(ReaderTheme)
        case lineWidthChanged(Double)
        case saveAppearance
        case saveAppearanceFinished
        case saveAppearanceFailed(String)

        case retryExtractionTapped
        case retryFinished(SavedItem?)
        case openInlineWebEmbed(String)
        case inlineEmbedURL(PresentationAction<InlineEmbedFeature.Action>)
        case switchRenderMode(RenderFormat)

        /// Emitted by the reader view when the top-visible block changes.
        /// Triggers a debounced save of the reading position.
        case scrollProgressChanged(Int)
        case saveReadingProgress(Int)

        /// User tapped the toolbar mark-read/unread button.
        case toggleReadTapped
    }

    private enum CancelID {
        case appearanceSave
        case readingProgressSave
        case progressPoll
    }

    @Dependency(\.stowerRepository) var repository
    @Dependency(\.urlIngestionClient) var ingestionClient
    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.readerProgressClient) var readerProgressClient

    public var body: some ReducerOf<Self> {
        Scope(state: \.speech, action: \.speech) {
            ReaderSpeechFeature()
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
                    return .none
                }

                state.isLoading = true
                state.errorMessage = nil
                let repository = self.repository
                let needsItem = state.item == nil
                return .run { [id = state.itemID] send in
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

            case .loaded(let item, let document, let sourceHTML):
                state.isLoading = false
                if let item { state.item = item }
                state.document = document
                state.sourceHTML = sourceHTML
                return .merge(
                    archiveIfNeeded(item: state.item, sourceHTML: sourceHTML),
                    startProgressPollingEffect()
                )

            case .failed(let error):
                state.isLoading = false
                state.errorMessage = error
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

            case .themeChanged(let value):
                state.appearance.theme = value
                return .send(.saveAppearance)

            case .lineWidthChanged(let value):
                state.appearance.lineWidth = value
                state.appearance.clamp()
                return .send(.saveAppearance)

            case .saveAppearance:
                let repository = self.repository
                return .run { [appearance = state.appearance] send in
                    do {
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
                guard let source = state.item?.sourceURL,
                      let url = URL(string: source)
                else {
                    state.errorMessage = "Source URL unavailable for refresh."
                    return .none
                }

                state.isLoading = true
                let repository = self.repository
                let ingestionClient = self.ingestionClient
                return .run { [id = state.itemID] send in
                    do {
                        let result = try await ingestionClient.ingest(url)
                        let item = try await repository.updateItemFromIngestion(id, result)

                        // Archive assets for offline WebView rendering.
                        if result.renderFormat == .webView,
                           !result.sourceHTML.isEmpty {
                            AssetArchiver.deleteArchive(for: id)
                            await AssetArchiver.archiveAssets(
                                html: result.sourceHTML,
                                baseURL: url,
                                itemID: id
                            )
                        }

                        await send(.retryFinished(item))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

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
                return .none

            case .scrollProgressChanged(let blockIndex):
                // Update local state immediately; debounce the DB write.
                // Block index 0 means "at the top" — don't persist it (treat
                // as "no restore state") so new opens don't get a false restore.
                guard blockIndex >= 0 else { return .none }
                state.item?.lastReadBlockIndex = blockIndex > 0 ? blockIndex : nil

                // Auto-mark as read the first time the user scrolls past the
                // intro. Guarded by `isRead == false` so we only fire once.
                var autoMarkEffect: Effect<Action> = .none
                if blockIndex > 0, state.item?.isRead == false {
                    state.item?.isRead = true
                    let repo = self.repository
                    let id = state.itemID
                    autoMarkEffect = .run { _ in
                        try? await repo.setReadStatus(id, true)
                    }
                }

                if blockIndex == 0 {
                    return .merge(
                        .cancel(id: CancelID.readingProgressSave),
                        autoMarkEffect
                    )
                }
                let clock = self.continuousClock
                let saveEffect: Effect<Action> = .run { send in
                    try? await clock.sleep(for: .seconds(1))
                    await send(.saveReadingProgress(blockIndex), animation: nil)
                }
                .cancellable(id: CancelID.readingProgressSave, cancelInFlight: true)
                return .merge(saveEffect, autoMarkEffect)

            case .saveReadingProgress(let blockIndex):
                let repository = self.repository
                return .run { [id = state.itemID] _ in
                    try? await repository.saveReadingProgress(id, blockIndex)
                }

            case .toggleReadTapped:
                guard var item = state.item else { return .none }
                let newValue = !item.isRead
                item.isRead = newValue
                state.item = item
                let repo = self.repository
                let id = state.itemID
                return .run { _ in try? await repo.setReadStatus(id, newValue) }

            case .speech:
                return .none
            }
        }
        .ifLet(\.$inlineEmbedURL, action: \.inlineEmbedURL) {
            InlineEmbedFeature()
        }
    }

    /// Triggers asset archiving if the article is a webView format but has no local archive.
    private func archiveIfNeeded(item: SavedItem?, sourceHTML: String?) -> Effect<Action> {
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

    /// Polls the currently registered reader `WebPage` every 1.5 seconds for
    /// the topmost visible block index and emits `scrollProgressChanged`
    /// actions when it changes. Runs as a child effect so `ifLet` cancels it
    /// atomically with presentation dismissal — unlike the previous manual
    /// `Task` inside `ReaderWebView`, which kept firing during the window
    /// between `navigationDestination`'s state nil-ification and the view's
    /// `.onDisappear`, and tripped a noisy TCA runtime warning on every pop.
    private func startProgressPollingEffect() -> Effect<Action> {
        let client = self.readerProgressClient
        let clock = self.continuousClock
        return .run { send in
            var lastReported: Int?
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1.5))
                if Task.isCancelled { return }
                guard let top = await client.topBlockIndex() else { continue }
                if Task.isCancelled { return }
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
