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

        public var effectiveRenderFormat: RenderFormat {
            renderModeOverride ?? .structuredV1
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
    }

    private enum CancelID {
        case appearanceSave
        case readingProgressSave
    }

    @Dependency(\.stowerRepository) var repository
    @Dependency(\.urlIngestionClient) var ingestionClient
    @Dependency(\.continuousClock) var continuousClock

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
                return archiveIfNeeded(item: state.item, sourceHTML: sourceHTML)

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
                if blockIndex == 0 {
                    return .cancel(id: CancelID.readingProgressSave)
                }
                let clock = self.continuousClock
                return .run { [id = state.itemID] send in
                    try? await clock.sleep(for: .seconds(1))
                    await send(.saveReadingProgress(blockIndex), animation: nil)
                    _ = id
                }
                .cancellable(id: CancelID.readingProgressSave, cancelInFlight: true)

            case .saveReadingProgress(let blockIndex):
                let repository = self.repository
                return .run { [id = state.itemID] _ in
                    try? await repository.saveReadingProgress(id, blockIndex)
                }

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
