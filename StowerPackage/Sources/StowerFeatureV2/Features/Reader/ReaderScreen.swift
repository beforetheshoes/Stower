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
    @State private var isListenPanelPresented = false
    @State private var isAIPanelPresented = false
    @State private var isPDFViewerPresented = false
    @State private var isFindNavigatorPresented = false

    /// Shorthand for the current palette tokens. Computed on the fly since
    /// `FlexokiPalette` is a cheap value type and tracking it through
    /// `@Environment` here would collide with the listen/AI highlight tints
    /// that conditionally override `.tint` on individual buttons.
    private var palette: FlexokiPalette { store.appearance.palette }

    public init(store: StoreOf<ReaderFeature>) {
        self.store = store
    }

    public var body: some View {
        content
            .background(store.appearance.backgroundColor)
            // Enables WKWebView's built-in find UI (iOS 26+ / macOS 26+).
            // Binding lets us toggle from the toolbar button below; the
            // system also binds this to its own Find menu item and the
            // Cmd+F keyboard shortcut, so both entry points dismiss the
            // same navigator.
            .findNavigator(isPresented: $isFindNavigatorPresented)
            .navigationTitle("Reader")
            .toolbar {
                // Group 1: mode switching (only when an interactive fallback exists).
                if store.hasInteractiveContent {
                    ToolbarItem(placement: .automatic) {
                        switchModeButton
                    }
                    ToolbarSpacer(.fixed, placement: .automatic)
                }

                // Group 2: content-level actions — Find and (for PDFs) Original PDF.
                ToolbarItem(placement: .automatic) {
                    Button {
                        isFindNavigatorPresented.toggle()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    // ⌘F — standard macOS find shortcut. The system's
                    // own Edit → Find menu item binds to the same
                    // state via the `findNavigator` modifier above, so
                    // either entry point toggles the find UI.
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Find in reader")
                }
                if store.item?.renderFormat == .pdf {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            isPDFViewerPresented = true
                        } label: {
                            Label("Original PDF", systemImage: "doc.richtext")
                        }
                        .help("Show the original PDF in PDFKit")
                    }
                }

                ToolbarSpacer(.fixed, placement: .automatic)

                // Group 3: reading-assist tools — Listen + AI. These get the
                // Liquid Glass prominent button style so they read as the
                // reader's primary floating actions.
                ToolbarItem(placement: .automatic) {
                    listenToolbarButton
                }
                ToolbarItem(placement: .automatic) {
                    aiToolbarButton
                }

                ToolbarSpacer(.fixed, placement: .automatic)

                // Group 4: presentation tweaks.
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
                            onBackgroundChanged: { store.send(.backgroundChanged($0)) },
                            onPrimaryAccentChanged: { store.send(.primaryAccentChanged($0)) },
                            onSecondaryAccentChanged: { store.send(.secondaryAccentChanged($0)) },
                            onLineWidthChanged: { store.send(.lineWidthChanged($0)) },
                            onDone: { isAppearancePanelPresented = false }
                        )
                        .frame(width: 400)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
            // No custom toolbar background — Liquid Glass paints the
            // nav/window bar automatically on iOS 26 / macOS 26, and the
            // reader's chosen background (`store.appearance.backgroundColor`
            // on line 33) still shows through under it.
            .task(id: store.itemID) { store.send(.load) }
            .sheet(item: $store.scope(state: \.inlineEmbedURL, action: \.inlineEmbedURL)) { embedStore in
                NavigationStack {
                    InlineEmbedScreen(store: embedStore)
                }
            }
            .sheet(isPresented: $isPDFViewerPresented) {
                PDFReaderSheet(
                    itemID: store.itemID,
                    title: store.item?.title ?? "PDF",
                    onDismiss: { isPDFViewerPresented = false }
                )
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
                onOpenInlineEmbed: { urlString in store.send(.openInlineWebEmbed(urlString)) }
            )
        } else if let item = store.item, item.content.isEmpty {
            downloadPrompt(item: item)
        } else if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            Text(error).foregroundStyle(store.appearance.palette.error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Item not found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Toolbar button that flips between the interactive (archive/WebView)
    /// rendering and the stripped structured reader view. Only shown when
    /// the article was ingested as `.webView`, so `hasInteractiveContent`
    /// gates its visibility upstream.
    ///
    /// Label + icon reflect the destination, not the current mode, so the
    /// user can always read it as "this is what I'm about to get".
    @ViewBuilder
    private var switchModeButton: some View {
        let isCurrentlyInteractive = store.effectiveRenderFormat == .webView
        let nextMode: RenderFormat = isCurrentlyInteractive ? .structuredV1 : .webView
        Button {
            store.send(.switchRenderMode(nextMode))
        } label: {
            if isCurrentlyInteractive {
                Label("Reader View", systemImage: "doc.plaintext")
            } else {
                Label("Interactive View", systemImage: "safari")
            }
        }
        .help(isCurrentlyInteractive
              ? "Show the stripped-down reader version of this article"
              : "Show the original interactive page with SVGs and scripts")
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

// MARK: - Listen toolbar button

extension ReaderScreen {
    @ViewBuilder
    fileprivate var listenToolbarButton: some View {
        let isActive = store.speech.isSpeaking && !store.speech.isPaused
        Button {
            isListenPanelPresented.toggle()
        } label: {
            Label("Listen", systemImage: listenButtonSymbol)
        }
        // No explicit buttonStyle — the toolbar already renders items as
        // Liquid Glass automatically on iOS 26 / macOS 26. Adding
        // `.buttonStyle(.glass)` with a forced tint on top rendered as a
        // solid filled capsule, which is the opposite of what we want.
        // The active-state tint only kicks in while speech is running so
        // the symbol shifts to the secondary accent; otherwise the button
        // inherits the window's `palette.primary` tint naturally.
        .tint(isActive ? palette.secondary : nil)
        .popover(isPresented: $isListenPanelPresented, arrowEdge: .top) {
            listenPanelContent
                .frame(width: 320)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }

    fileprivate var listenButtonSymbol: String {
        if store.speech.isSpeaking {
            return store.speech.isPaused ? "speaker.slash" : "speaker.wave.2.fill"
        }
        return "speaker.wave.2"
    }

    @ViewBuilder
    fileprivate var listenPanelContent: some View {
        // Start from block-level speech output (one unit per paragraph /
        // heading / list / etc.) and then expand each block into
        // sentence-level units so the Listen skip buttons move by
        // sentence instead of by paragraph. Sentences inherit their
        // parent block's `index` (for scroll / highlight) but get a
        // fresh monotonic `sequence` the feature uses for skip
        // filtering.
        let blockLevel = ReaderSpeechTextBuilder.speechBlocks(
            item: store.item,
            document: store.document
        )
        let speechBlocks = ReaderSpeechTextBuilder.sentenceSplit(blockLevel)
        ReaderListenControls(
            speech: store.speech,
            speechBlocks: speechBlocks,
            onListen: { store.send(.speech(.listenTapped(blocks: speechBlocks))) },
            onPause: { store.send(.speech(.pauseTapped)) },
            onResume: { store.send(.speech(.resumeTapped)) },
            onStop: { store.send(.speech(.stopTapped)) },
            onSkipBackward: { store.send(.speech(.skipBackwardTapped)) },
            onSkipForward: { store.send(.speech(.skipForwardTapped)) },
            onRateChanged: { store.send(.speech(.rateChanged($0))) },
            onVoiceChanged: { store.send(.speech(.voiceChanged($0))) }
        )
    }
}

// MARK: - AI toolbar button

extension ReaderScreen {
    @ViewBuilder
    fileprivate var aiToolbarButton: some View {
        let isActive = store.ai.isSummarizing || store.ai.isAnswering
        Button {
            isAIPanelPresented.toggle()
        } label: {
            Label("AI tools", systemImage: aiButtonSymbol)
        }
        // Same as Listen: no explicit buttonStyle (the toolbar's automatic
        // Liquid Glass does the work), and the secondary-accent tint only
        // fires when AI is actively summarizing or answering.
        .tint(isActive ? palette.secondary : nil)
        .popover(isPresented: $isAIPanelPresented, arrowEdge: .top) {
            ReaderAIControls(
                store: store.scope(state: \.ai, action: \.ai),
                document: store.document,
                plainText: resolvedAIPlainText
            )
            // `idealWidth`/`idealHeight` is a hint, not a constraint — on
            // macOS popovers SwiftUI will collapse the content to its
            // intrinsic minimum (which for a ScrollView is zero). Pin a
            // real minimum so the summary is actually readable.
            .frame(
                minWidth: 380,
                idealWidth: 420,
                minHeight: 480,
                idealHeight: 520
            )
            .presentationCompactAdaptation(.popover)
            .onDisappear { store.send(.ai(.cancelAll)) }
        }
    }

    fileprivate var aiButtonSymbol: String {
        if store.ai.isSummarizing || store.ai.isAnswering {
            return "sparkles.rectangle.stack"
        }
        return "sparkles"
    }

    /// Article text fed into the AI client. Prefers text derived from
    /// structured `ReaderDocument` blocks — the same source of truth the
    /// reader uses for rendering and TTS — because `SavedItem.content` can
    /// be empty for articles that were ingested without persisting a
    /// plain-text copy (webView items, older ingestions). Falls back to
    /// `item.content` so plain-text notes still work.
    fileprivate var resolvedAIPlainText: String {
        if let document = store.document {
            let blocks = ReaderSpeechTextBuilder.speechBlocks(document: document)
            if !blocks.isEmpty {
                return blocks.map(\.text).joined(separator: "\n\n")
            }
        }
        return store.item?.content ?? ""
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
