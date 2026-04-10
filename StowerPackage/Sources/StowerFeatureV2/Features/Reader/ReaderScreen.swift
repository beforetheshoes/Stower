import ComposableArchitecture
import SwiftUI
import WebKit

/// The reader screen.
///
/// All articles — structured, plain-text, and interactive webView format —
/// render through a single `ReaderWebView`. Structured `ReaderDocument`s are
/// converted to HTML via `ReaderDocumentHTMLBuilder` on demand. This gives us
/// native HTML performance (virtualized layout, native text selection, native
/// find-in-page) and eliminates the SwiftUI `LazyVStack` rendering path that
/// failed to scale on large documents.
public struct ReaderScreen: View {
    @Bindable var store: StoreOf<ReaderFeature>
    @State private var isAppearancePanelPresented = false

    public init(store: StoreOf<ReaderFeature>) {
        self.store = store
    }

    public var body: some View {
        content
            .background(store.appearance.backgroundColor)
            .navigationTitle("Reader")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isAppearancePanelPresented.toggle()
                    } label: {
                        Label("Appearance", systemImage: "textformat.size")
                    }
                    .popover(isPresented: $isAppearancePanelPresented, arrowEdge: .top) {
                        ReaderAppearanceControls(
                            appearance: store.appearance,
                            onFontSizeChanged: { store.send(.fontSizeChanged($0)) },
                            onFontStyleChanged: { store.send(.fontStyleChanged($0)) },
                            onLineSpacingChanged: { store.send(.lineSpacingChanged($0)) },
                            onJustificationChanged: { store.send(.justificationChanged($0)) },
                            onThemeChanged: { store.send(.themeChanged($0)) },
                            onLineWidthChanged: { store.send(.lineWidthChanged($0)) },
                            onDone: { isAppearancePanelPresented = false }
                        )
                        .frame(width: 360)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
            #if os(macOS)
            .toolbarBackground(store.appearance.surfaceColor, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            #else
            .toolbarBackground(store.appearance.surfaceColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .task(id: store.itemID) { store.send(.load) }
            .sheet(item: $store.scope(state: \.inlineEmbedURL, action: \.inlineEmbedURL)) { embedStore in
                NavigationStack {
                    InlineEmbedScreen(store: embedStore)
                }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let item = store.item, let resolvedHTML = resolvedHTML(for: item) {
            ReaderWebView(
                html: resolvedHTML,
                sourceURL: item.sourceURL,
                itemID: store.itemID,
                appearance: store.appearance,
                isWebViewFormat: store.effectiveRenderFormat == .webView,
                highlightedBlockIndex: store.speech.currentBlockIndex,
                restoreBlockIndex: item.lastReadBlockIndex,
                onSwitchToNative: store.hasInteractiveContent
                    ? { store.send(.switchRenderMode(store.effectiveRenderFormat == .webView ? .structuredV1 : .webView)) }
                    : nil,
                onReadingProgress: { index in store.send(.scrollProgressChanged(index)) },
                onOpenInlineEmbed: { urlString in store.send(.openInlineWebEmbed(urlString)) }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReaderBottomBar(store: store)
            }
        } else if let item = store.item, item.content.isEmpty {
            downloadPrompt(item: item)
        } else if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            Text(error).foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Item not found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Picks the right HTML to show. For interactive articles (`webView`
    /// format) we hand WKWebView the raw captured `sourceHTML` unchanged.
    /// For all other articles we generate a clean HTML document from the
    /// structured `ReaderDocument`.
    private func resolvedHTML(for item: SavedItem) -> String? {
        if store.effectiveRenderFormat == .webView {
            return store.sourceHTML
        }
        guard let document = store.document else { return nil }
        return ReaderDocumentHTMLBuilder.buildReaderHTML(
            item: item,
            document: document,
            appearance: store.appearance
        )
    }

    // MARK: - Download prompt

    @ViewBuilder
    private func downloadPrompt(item: SavedItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download to read")
                .font(.headline)
                .foregroundStyle(store.appearance.primaryTextColor)
            Text("This item is synced, but the full content is stored locally per device.")
                .font(.subheadline)
                .foregroundStyle(store.appearance.secondaryTextColor)

            if item.processingState == .extracting || store.isLoading {
                ProgressView()
                    .padding(.top, 6)
            } else {
                Button("Download") {
                    store.send(.retryExtractionTapped)
                }
                .buttonStyle(.borderedProminent)
            }

            if item.processingState == .partial || item.processingState == .failed {
                Button("Improve Formatting") {
                    store.send(.retryExtractionTapped)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bottom Bar (Listen Controls)

private struct ReaderBottomBar: View {
    @Bindable var store: StoreOf<ReaderFeature>

    var body: some View {
        let speechBlocks = ReaderSpeechTextBuilder.speechBlocks(
            item: store.item,
            document: store.document
        )
        ReaderListenControls(
            speech: store.speech,
            speechBlocks: speechBlocks,
            onListen: { store.send(.speech(.listenTapped(blocks: speechBlocks))) },
            onPause: { store.send(.speech(.pauseTapped)) },
            onResume: { store.send(.speech(.resumeTapped)) },
            onStop: { store.send(.speech(.stopTapped)) },
            onRateChanged: { store.send(.speech(.rateChanged($0))) },
            onVoiceChanged: { store.send(.speech(.voiceChanged($0))) },
            surfaceColor: store.appearance.surfaceColor,
            secondaryTextColor: store.appearance.secondaryTextColor
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Inline Embed

private struct InlineEmbedScreen: View {
    let store: StoreOf<InlineEmbedFeature>
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .ignoresSafeArea()
            .navigationTitle("Embed")
            .task { _ = page.load(URLRequest(url: store.url)) }
    }
}
