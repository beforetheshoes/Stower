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
    @State private var session: ReaderWebSession
    @ScaledMetric(relativeTo: .body)
    private var dynamicBodySize: CGFloat = 19
    private let isReaderFocused: Bool
    private let onToggleReaderFocus: (() -> Void)?

    /// Shorthand for the current palette tokens. Computed on the fly since
    /// `FlexokiPalette` is a cheap value type and tracking it through
    /// `@Environment` here would collide with the listen/AI highlight tints
    /// that conditionally override `.tint` on individual buttons.
    private var palette: FlexokiPalette { store.appearance.palette }

    public init(
        store: StoreOf<ReaderFeature>,
        session: ReaderWebSession = ReaderWebSession(),
        isReaderFocused: Bool = false,
        onToggleReaderFocus: (() -> Void)? = nil
    ) {
        self.store = store
        self._session = State(initialValue: session)
        self.isReaderFocused = isReaderFocused
        self.onToggleReaderFocus = onToggleReaderFocus
    }

    public var body: some View {
        content
            .background(store.appearance.backgroundColor)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let progress = store.readingProgress {
                    readerProgressHeader(progress)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                store.send(.viewportWidthChanged(Double(newWidth)))
            }
            // Enables WKWebView's built-in find UI (iOS 26+ / macOS 26+).
            // Binding lets us toggle from the toolbar button below; the
            // system also binds this to its own Find menu item and the
            // Cmd+F keyboard shortcut, so both entry points dismiss the
            // same navigator.
            .findNavigator(isPresented: $session.isFindNavigatorPresented)
            .navigationTitle("Reader")
#if os(macOS)
            .toolbar(store.isChromeHidden ? .hidden : .visible, for: .windowToolbar)
#else
            .toolbar(store.isChromeHidden ? .hidden : .visible, for: .navigationBar)
#endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        store.send(.doneTapped)
                    }
                    .bold()
                    .accessibilityHint("Moves this article out of Inbox but keeps it in Library")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Appearance", systemImage: "textformat.size") {
                        session.isAppearancePanelPresented.toggle()
                    }
                    .popover(isPresented: $session.isAppearancePanelPresented, arrowEdge: .top) {
                        ReaderAppearanceControls(
                            appearance: store.appearance,
                            lineWidthPolicy: store.lineWidthPolicy,
                            onFontSizeChanged: { store.send(.fontSizeChanged($0)) },
                            onFontStyleChanged: { store.send(.fontStyleChanged($0)) },
                            onLineSpacingChanged: { store.send(.lineSpacingChanged($0)) },
                            onJustificationChanged: { store.send(.justificationChanged($0)) },
                            onBackgroundChanged: { store.send(.backgroundChanged($0)) },
                            onPrimaryAccentChanged: { store.send(.primaryAccentChanged($0)) },
                            onSecondaryAccentChanged: { store.send(.secondaryAccentChanged($0)) },
                            onLineWidthChanged: { store.send(.lineWidthChanged($0)) },
                            onDone: { session.isAppearancePanelPresented = false }
                        )
                        .frame(width: 400)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    readerMoreMenu
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button("Done", systemImage: "checkmark") {
                        store.send(.doneTapped)
                    }
                    .bold()
                    .help("Move out of Inbox and keep in Library")
                }
                ToolbarSpacer(.fixed, placement: .automatic)

                if let onToggleReaderFocus {
                    ToolbarItem(placement: .automatic) {
                        Button(action: onToggleReaderFocus) {
                            Label(
                                isReaderFocused ? "Exit Focus" : "Focus Reader",
                                systemImage: isReaderFocused
                                    ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right"
                            )
                        }
                        #if os(iOS)
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        #endif
                        .help(isReaderFocused ? "Exit reader focus" : "Focus on this article")
                        .accessibilityIdentifier("reader.focus")
                    }
                    .visibilityPriority(.high)
                }

                // Group 1: mode switching. Available whenever the original
                // source HTML is on hand so the user can flip to the full
                // web view — useful for SVG-heavy pages, interactive
                // embeds, or anything the structured parser strips.
                if (store.item?.captureVersion ?? 0) > 0 || store.sourceHTML != nil {
                    ToolbarItem(placement: .automatic) {
                        switchModeButton
                    }
                    .visibilityPriority(.low)
                    ToolbarSpacer(.fixed, placement: .automatic)
                }

                // Group 2: content-level actions — Find and (for PDFs) Original PDF.
                ToolbarItem(placement: .automatic) {
                    Button {
                        session.isFindNavigatorPresented.toggle()
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
                .visibilityPriority(.low)
                if store.canEditTextSource {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            store.send(.editTextTapped)
                        } label: {
                            Label("Edit", systemImage: "square.and.pencil")
                        }
                        .help("Edit this text or markdown item")
                    }
                    .visibilityPriority(.low)
                }
                if store.item?.renderFormat == .pdf {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            session.isPDFViewerPresented = true
                        } label: {
                            Label("Original PDF", systemImage: "doc.richtext")
                        }
                        .help("Show the original PDF in PDFKit")
                    }
                    .visibilityPriority(.low)
                }

                ToolbarSpacer(.fixed, placement: .automatic)

                // Group 3: reading-assist tools — Listen + AI. These get the
                // Liquid Glass prominent button style so they read as the
                // reader's primary floating actions.
                ToolbarItem(placement: .automatic) {
                    listenToolbarButton
                }
                .visibilityPriority(.high)
                ToolbarItem(placement: .automatic) {
                    aiToolbarButton
                }

                ToolbarSpacer(.fixed, placement: .automatic)

                // Group 4: presentation tweaks.
                ToolbarItem(placement: .automatic) {
                    Button {
                        session.isAppearancePanelPresented.toggle()
                    } label: {
                        Label("Appearance", systemImage: "textformat.size")
                    }
                    .popover(isPresented: $session.isAppearancePanelPresented, arrowEdge: .top) {
                        ReaderAppearanceControls(
                            appearance: store.appearance,
                            lineWidthPolicy: store.lineWidthPolicy,
                            onFontSizeChanged: { store.send(.fontSizeChanged($0)) },
                            onFontStyleChanged: { store.send(.fontStyleChanged($0)) },
                            onLineSpacingChanged: { store.send(.lineSpacingChanged($0)) },
                            onJustificationChanged: { store.send(.justificationChanged($0)) },
                            onBackgroundChanged: { store.send(.backgroundChanged($0)) },
                            onPrimaryAccentChanged: { store.send(.primaryAccentChanged($0)) },
                            onSecondaryAccentChanged: { store.send(.secondaryAccentChanged($0)) },
                            onLineWidthChanged: { store.send(.lineWidthChanged($0)) },
                            onDone: { session.isAppearancePanelPresented = false }
                        )
                        .frame(width: 400)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                    }
                }
                .visibilityPriority(.low)
                #endif
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
            .sheet(isPresented: $session.isPDFViewerPresented) {
                PDFReaderSheet(
                    itemID: store.itemID,
                    title: store.item?.title ?? "PDF"
                ) {
                    session.isPDFViewerPresented = false
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { store.textEditor != nil },
                    set: { isPresented in
                        if !isPresented {
                            store.send(.textEditorDismissed)
                        }
                    }
                )
            ) {
                TextAuthoringSheet(
                    title: Binding(
                        get: { store.textEditor?.title ?? "" },
                        set: { store.send(.textEditorTitleChanged($0)) }
                    ),
                    text: Binding(
                        get: { store.textEditor?.text ?? "" },
                        set: { store.send(.textEditorTextChanged($0)) }
                    ),
                    mode: Binding(
                        get: { store.textEditor?.mode ?? .plainText },
                        set: { store.send(.textEditorModeChanged($0)) }
                    ),
                    palette: palette,
                    errorMessage: store.textEditor?.errorMessage,
                    isSaving: store.textEditor?.isSaving ?? false,
                    navigationTitle: "Edit",
                    onCancel: {
                        store.send(.textEditorDismissed)
                    },
                    onSave: {
                        store.send(.saveTextEditTapped)
                    },
                    appearance: store.appearance
                )
            }
            #if os(iOS)
            .sheet(isPresented: $session.isListenPanelPresented) {
                NavigationStack {
                    listenPanelContent
                        .padding()
                        .navigationTitle("Listen")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { session.isListenPanelPresented = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $session.isAIPanelPresented) {
                NavigationStack {
                    ReaderAIControls(
                        store: store.scope(\.ai, action: \.ai),
                        document: store.document,
                        plainText: resolvedAIPlainText
                    )
                    .navigationTitle("Article Tools")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { session.isAIPanelPresented = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .onDisappear { store.send(.ai(.cancelAll)) }
            }
            #endif
    }

    #if os(iOS)
    @ViewBuilder private var readerMoreMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            if (store.item?.captureVersion ?? 0) > 0 || store.sourceHTML != nil {
                switchModeButton
            }

            Button("Find in Article", systemImage: "magnifyingglass") {
                session.isFindNavigatorPresented.toggle()
            }

            if store.canEditTextSource {
                Button("Edit", systemImage: "square.and.pencil") {
                    store.send(.editTextTapped)
                }
            }

            if store.item?.renderFormat == .pdf {
                Button("Original PDF", systemImage: "doc.richtext") {
                    session.isPDFViewerPresented = true
                }
            }

            Divider()

            Button("Listen", systemImage: "speaker.wave.2") {
                session.isListenPanelPresented = true
            }
            Button("Article Tools", systemImage: "sparkles") {
                store.send(.ai(.panelOpened))
                session.isAIPanelPresented = true
            }

            if let onToggleReaderFocus {
                Button(
                    isReaderFocused ? "Exit Focus" : "Focus Reader",
                    systemImage: isReaderFocused
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    action: onToggleReaderFocus
                )
            }

            Divider()

            if let source = store.item?.sourceURL.flatMap(URL.init(string:)) {
                ShareLink(
                    item: source,
                    subject: Text(store.item?.title ?? "Article")
                ) {
                    Label("Share Original", systemImage: "square.and.arrow.up")
                }
            }

            ShareLink(item: readerIssueReport) {
                Label("Report Reader Issue", systemImage: "exclamationmark.bubble")
            }

            Button("Refresh Reader View", systemImage: "arrow.clockwise") {
                store.send(.retryExtractionTapped)
            }
        }
    }

    private var readerIssueReport: String {
        """
        Stower Reader issue

        Article: \(store.item?.title ?? "Unknown")
        Source: \(store.item?.sourceURL ?? "No source URL")
        Render mode: \(store.effectiveRenderFormat.rawValue)
        """
    }
    #endif

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let item = store.item, hasRenderableContent(for: item) {
            VStack(spacing: 0) {
                if item.processingState == .partial {
                    partialCaptureBanner(for: item)
                }
                ReaderWebView(
                    html: { resolvedHTML(for: item) ?? "" },
                    sourceURL: item.sourceURL,
                    itemID: store.itemID,
                    contentVersion: contentReloadToken(for: item),
                    appearance: store.appearance,
                    fontScale: readerFontScale,
                    session: session,
                    viewportWidth: store.viewportWidth,
                    isWebViewFormat: store.effectiveRenderFormat == .webView,
                    usesNativeCapture: item.captureVersion > 0,
                    highlightedBlockIndex: store.speech.currentBlockIndex,
                    restoreBlockIndex: item.lastReadBlockIndex,
                    onOpenInlineEmbed: { urlString in
                        store.send(.openInlineWebEmbed(urlString))
                    },
                    onContentTap: {
                        handleContentTap()
                    }
                )
            }
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

    private func hasRenderableContent(for item: SavedItem) -> Bool {
        if item.captureVersion > 0,
           ArticleCapturePackage.archiveURL(
               for: item.id,
               original: store.effectiveRenderFormat == .webView
           ) != nil {
            return true
        }
        if store.effectiveRenderFormat == .webView {
            // URL-ingested archives carry their captured HTML in
            // `sourceHTML`. User-imported website zips don't — they unpack
            // straight to disk and leave sourceHTML empty, so also accept an
            // on-disk archive directory as evidence the site is renderable.
            if store.sourceHTML != nil {
                return true
            }
            return AssetArchiver.archiveExists(for: item.id)
        }
        return store.document != nil
    }

    private func partialCaptureWarning(for item: SavedItem) -> String {
        let warnings = ArticleCapturePackage.metadata(for: item.id)?.warnings ?? []
        return warnings.isEmpty
            ? "Some article media could not be saved for offline use."
            : warnings.joined(separator: " ")
    }

    private func partialCaptureBanner(for item: SavedItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(store.appearance.palette.warning)
                .accessibilityHidden(true)
            Text(partialCaptureWarning(for: item))
                .font(.footnote)
                .foregroundStyle(store.appearance.secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Refresh") {
                store.send(.retryExtractionTapped)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(store.appearance.palette.warning.opacity(0.12))
    }

    /// Toolbar button that flips between the interactive (archive/WebView)
    /// rendering and the stripped structured reader view. Only shown when
    /// the article was ingested as `.webView`, so `hasInteractiveContent`
    /// gates its visibility upstream.
    ///
    /// Label + icon reflect the destination, not the current mode, so the
    /// user can always read it as "this is what I'm about to get".
    @ViewBuilder private var switchModeButton: some View {
        let isCurrentlyInteractive = store.effectiveRenderFormat == .webView
        let nextMode: RenderFormat = isCurrentlyInteractive ? .structuredV1 : .webView
        Button {
            store.send(.switchRenderMode(nextMode))
        } label: {
            if isCurrentlyInteractive {
                Label("Reader View", systemImage: "doc.plaintext")
            } else {
                Label("Original View", systemImage: "safari")
            }
        }
        .help(isCurrentlyInteractive
              ? "Show the stripped-down reader version of this article"
              : "Show the original saved page with SVGs and interactive content")
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
            appearance: store.appearance,
            pageWidth: CGFloat(store.viewportWidth ?? 0),
            fontScale: readerFontScale
        )
    }

    private func contentReloadToken(for item: SavedItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.id)
        hasher.combine(item.updatedAt)
        hasher.combine(item.renderFormat.rawValue)
        hasher.combine(item.captureVersion)
        hasher.combine(store.effectiveRenderFormat.rawValue)
        hasher.combine(store.sourceHTML?.count)

        if let document = store.document {
            hasher.combine(document.version)
            hasher.combine(document.title)
            hasher.combine(document.sourceURL)
            hasher.combine(document.canonicalURL)
            hasher.combine(document.blocks.count)
        }

        return hasher.finalize()
    }

    private var readerFontScale: Double {
        Double(dynamicBodySize / 19)
    }

    private func handleContentTap() {
        let hasPresentedControls = session.isAppearancePanelPresented
            || session.isListenPanelPresented
            || session.isAIPanelPresented
            || session.isPDFViewerPresented
            || session.isFindNavigatorPresented

        session.isAppearancePanelPresented = false
        session.isListenPanelPresented = false
        session.isAIPanelPresented = false
        session.isPDFViewerPresented = false
        session.isFindNavigatorPresented = false

        guard !hasPresentedControls else { return }

        _ = withAnimation(.easeInOut(duration: 0.2)) {
            store.send(.contentAreaTapped)
        }
    }

    @ViewBuilder
    private func readerProgressHeader(_ progress: ReadingProgressSnapshot) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 0)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(palette.ui.opacity(0.3))
                Rectangle()
                    .fill(palette.primary)
                    .frame(width: width * progress.fractionComplete)
            }
        }
        .frame(height: 3)
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(progress.percentComplete) percent")
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
                Button("Refresh Reader View") {
                    store.send(.retryExtractionTapped)
                }
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(store.appearance.palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Listen toolbar button

extension ReaderScreen {
    @ViewBuilder private var listenToolbarButton: some View {
        let isActive = store.speech.isSpeaking && !store.speech.isPaused
        Button {
            session.isListenPanelPresented.toggle()
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
        .popover(isPresented: $session.isListenPanelPresented, arrowEdge: .top) {
            listenPanelContent
                .frame(width: 320)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var listenButtonSymbol: String {
        if store.speech.isSpeaking {
            return store.speech.isPaused ? "speaker.slash" : "speaker.wave.2.fill"
        }
        return "speaker.wave.2"
    }

    @ViewBuilder private var listenPanelContent: some View {
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
    @ViewBuilder private var aiToolbarButton: some View {
        let isActive = store.ai.isSummarizing || store.ai.isAnswering
        Button {
            if !session.isAIPanelPresented {
                store.send(.ai(.panelOpened))
            }
            session.isAIPanelPresented.toggle()
        } label: {
            Label("AI tools", systemImage: aiButtonSymbol)
        }
        // Same as Listen: no explicit buttonStyle (the toolbar's automatic
        // Liquid Glass does the work), and the secondary-accent tint only
        // fires when AI is actively summarizing or answering.
        .tint(isActive ? palette.secondary : nil)
        .popover(isPresented: $session.isAIPanelPresented, arrowEdge: .top) {
            ReaderAIControls(
                store: store.scope(\.ai, action: \.ai),
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

    private var aiButtonSymbol: String {
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
    private var resolvedAIPlainText: String {
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
