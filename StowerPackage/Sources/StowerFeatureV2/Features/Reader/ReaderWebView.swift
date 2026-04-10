import SwiftUI
import WebKit

/// Renders articles in a WKWebView — the single rendering path for the reader.
///
/// Two content sources are supported:
///  - **Interactive** (`isWebViewFormat == true`): the raw captured article
///    HTML is served through the local archive server so embedded JS/CSS/assets
///    work for offline viewing of dynamic pages.
///  - **Structured** (`isWebViewFormat == false`): a ready-to-display HTML
///    document produced by `ReaderDocumentHTMLBuilder` is loaded inline.
///
/// CSS is injected directly into the HTML before loading; live theme/font
/// changes use JavaScript to update the `<style id="stower-reader-css">` in
/// place. Reading position is polled from the page and persisted via
/// `onReadingProgress`. TTS highlighting is driven by the `highlightedBlockIndex`
/// binding and mapped through `ReaderWebPageFactory.runHighlight`.
public struct ReaderWebView: View {
    let html: String
    let sourceURL: String?
    let itemID: UUID
    let appearance: ReaderAppearanceSettings
    let isWebViewFormat: Bool
    let highlightedBlockIndex: Int?
    let restoreBlockIndex: Int?
    let onReadingProgress: ((Int) -> Void)?
    let onOpenInlineEmbed: ((String) -> Void)?

    @State private var page: WebPage?
    @State private var archiveServer: LocalArchiveServer?
    @State private var hasRestoredPosition = false
    @State private var progressTimerTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL

    public init(
        html: String,
        sourceURL: String?,
        itemID: UUID,
        appearance: ReaderAppearanceSettings,
        isWebViewFormat: Bool = false,
        highlightedBlockIndex: Int? = nil,
        restoreBlockIndex: Int? = nil,
        onReadingProgress: ((Int) -> Void)? = nil,
        onOpenInlineEmbed: ((String) -> Void)? = nil
    ) {
        self.html = html
        self.sourceURL = sourceURL
        self.itemID = itemID
        self.appearance = appearance
        self.isWebViewFormat = isWebViewFormat
        self.highlightedBlockIndex = highlightedBlockIndex
        self.restoreBlockIndex = restoreBlockIndex
        self.onReadingProgress = onReadingProgress
        self.onOpenInlineEmbed = onOpenInlineEmbed
    }

    public var body: some View {
        // The container has to always occupy real space, even before the
        // `WebPage` has been created by `loadContent()`. `Group { if let }`
        // resolves to `EmptyView` while `page == nil`, which gives the
        // parent a zero-sized child — the WebView then never gets real
        // bounds when `page` finally becomes non-nil. A `ZStack` with the
        // theme color as its first layer guarantees the container is
        // flexibly-filled regardless of whether the WebView is ready yet.
        ZStack {
            appearance.backgroundColor

            if let page {
                WebView(page)
                    .webViewContentBackground(.hidden)
            }
        }
        .task(id: itemID) {
            loadContent()
        }
        .onChange(of: appearance) { _, newAppearance in
            updateCSS(newAppearance)
        }
        .onChange(of: page?.isLoading) { _, isLoading in
            if isLoading == false {
                // Re-apply CSS in case appearance settings loaded after
                // the initial HTML was composed, then restore scroll and
                // start the reading-progress poll loop.
                updateCSS(appearance)
                maybeRestorePosition()
                startProgressPolling()
            }
        }
        .onChange(of: highlightedBlockIndex) { _, newValue in
            runHighlight(newValue)
        }
        .onDisappear {
            progressTimerTask?.cancel()
            progressTimerTask = nil
            archiveServer?.stop()
            archiveServer = nil
        }
    }

    // MARK: - Loading

    @MainActor
    private func loadContent() {
        // Clean up previous state.
        progressTimerTask?.cancel()
        progressTimerTask = nil
        archiveServer?.stop()
        archiveServer = nil
        page = nil
        hasRestoredPosition = false

        let hasArchive = AssetArchiver.archiveExists(for: itemID)
        let isArchive = isWebViewFormat && hasArchive

        let currentHTML = html
        let currentSourceURL = sourceURL
        let currentItemID = itemID
        let currentAppearance = appearance
        let openEmbed = onOpenInlineEmbed ?? { _ in }

        Task {
            if isArchive {
                let (loadURL, server) = await Self.prepareArchive(
                    html: currentHTML,
                    sourceURL: currentSourceURL,
                    itemID: currentItemID,
                    appearance: currentAppearance
                )
                guard let loadURL, let server else { return }

                let newPage = ReaderWebPageFactory.makePage(
                    openExternalURL: { [openURL] url in openURL(url) },
                    openInlineEmbed: { openEmbed($0) }
                )
                self.archiveServer = server
                _ = newPage.load(URLRequest(url: loadURL))
                self.page = newPage
            } else {
                // Structured / HTML-fallback path.
                //
                // YouTube-card documents contain an iframe that loads
                // youtube-nocookie.com/embed/…. If we hand WKWebView the HTML
                // via `load(html:baseURL:)` with the item's sourceURL as the
                // base, the document's origin becomes youtube.com — and
                // YouTube's embed player rejects what then looks like a
                // youtube.com page embedding its own videos (error 152-4).
                // Serving the HTML through the same `LocalArchiveServer` used
                // for archived pages gives the document a legitimate
                // `http://localhost:PORT` origin, and the embed player
                // accepts it. Non-YouTube structured articles go through the
                // same path too for consistency — the server startup cost is
                // ~10ms, well below perceivable latency.
                if let (loadURL, server) = await Self.prepareStructuredServer(
                    html: currentHTML,
                    itemID: currentItemID
                ) {
                    let newPage = ReaderWebPageFactory.makePage(
                        openExternalURL: { [openURL] url in openURL(url) },
                        openInlineEmbed: { openEmbed($0) }
                    )
                    self.archiveServer = server
                    _ = newPage.load(URLRequest(url: loadURL))
                    self.page = newPage
                } else {
                    // Fallback: if the scratch dir write or server start fails,
                    // fall back to the original in-memory load so the reader
                    // still shows content (the only thing we lose is YouTube
                    // embed playback on that particular open).
                    let base = currentSourceURL.flatMap(URL.init(string:)) ?? URL(string: "about:blank")!
                    let newPage = ReaderWebPageFactory.makePage(
                        openExternalURL: { [openURL] url in openURL(url) },
                        openInlineEmbed: { openEmbed($0) }
                    )
                    _ = newPage.load(html: currentHTML, baseURL: base)
                    self.page = newPage
                }
            }
        }
    }

    /// Writes the structured reader HTML into a per-item scratch directory and
    /// starts a `LocalArchiveServer` pointing at it. The returned URL is what
    /// the WebView should load; the returned server must be retained for the
    /// lifetime of the reader view and stopped on dismiss.
    private nonisolated static func prepareStructuredServer(
        html: String,
        itemID: UUID
    ) async -> (URL, LocalArchiveServer)? {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowerReader", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
            let indexURL = scratchDir.appendingPathComponent("index.html")
            try Data(html.utf8).write(to: indexURL, options: .atomic)
        } catch {
            return nil
        }

        let server = LocalArchiveServer(archiveDir: scratchDir, articlePath: "/", originURL: nil)
        guard let port = try? await server.start() else { return nil }
        let loadURL = URL(string: "http://localhost:\(port)/")!
        return (loadURL, server)
    }

    /// Prepares archive content off the main actor: patches HTML, injects CSS, starts server.
    private nonisolated static func prepareArchive(
        html: String,
        sourceURL: String?,
        itemID: UUID,
        appearance: ReaderAppearanceSettings
    ) async -> (URL?, LocalArchiveServer?) {
        // Interactive mode shows the original archived page unmodified —
        // that is the whole point of the `.webView` format. No theme CSS
        // injection, no background overrides. If the user wants themed,
        // comfortable text they switch to Reader View from the toolbar.
        if !html.isEmpty {
            AssetArchiver.refreshIndexHTML(for: itemID, sourceHTML: html)
        } else {
            AssetArchiver.refreshIndexHTML(for: itemID)
        }
        // Wipe any overlay CSS block baked in by an older build.
        AssetArchiver.stripLegacyInjectedCSS(for: itemID)

        let archiveDir = AssetArchiver.archiveDirectory(for: itemID)
        let sourceURLValue = sourceURL.flatMap(URL.init(string:))
        let articlePath = sourceURLValue?.path ?? "/"

        // Resolve the origin used by the local server's fetch-through.
        // Prefer the fresh `sourceURL` from the caller; fall back to the
        // archive's persisted metadata so archives created before the
        // metadata sidecar existed still self-heal on first open.
        let originURL: URL? = {
            if let sourceURLValue {
                var components = URLComponents(url: sourceURLValue, resolvingAgainstBaseURL: false)
                components?.path = ""
                components?.query = nil
                components?.fragment = nil
                if let stripped = components?.url {
                    AssetArchiver.saveMetadata(origin: stripped, for: itemID)
                    return stripped
                }
            }
            return AssetArchiver.loadOriginURL(for: itemID)
        }()

        let server = LocalArchiveServer(
            archiveDir: archiveDir,
            articlePath: articlePath,
            originURL: originURL
        )
        guard let port = try? await server.start() else { return (nil, nil) }

        let loadURL = URL(string: "http://localhost:\(port)\(articlePath)")!
        return (loadURL, server)
    }

    // MARK: - Live CSS updates

    @MainActor
    private func updateCSS(_ appearance: ReaderAppearanceSettings) {
        guard let page else { return }

        // Interactive mode: leave the original page untouched. Appearance
        // settings apply only to Reader View.
        if isWebViewFormat && AssetArchiver.archiveExists(for: itemID) {
            return
        }

        let css = appearance.readerCSS(pageWidth: 10_000)
        Task {
            await ReaderWebPageFactory.updateCSS(css, on: page)
        }
    }

    // MARK: - Highlight

    @MainActor
    private func runHighlight(_ index: Int?) {
        guard let page else { return }
        Task {
            await ReaderWebPageFactory.runHighlight(index, on: page)
        }
    }

    // MARK: - Restore reading position

    @MainActor
    private func maybeRestorePosition() {
        guard let page, !hasRestoredPosition, let restoreBlockIndex, restoreBlockIndex > 0 else {
            hasRestoredPosition = true
            return
        }
        hasRestoredPosition = true
        Task {
            // Slight delay to let layout settle after load.
            try? await Task.sleep(nanoseconds: 150_000_000)
            await ReaderWebPageFactory.scrollToBlock(restoreBlockIndex, on: page)
        }
    }

    // MARK: - Progress polling

    @MainActor
    private func startProgressPolling() {
        progressTimerTask?.cancel()
        guard onReadingProgress != nil else { return }

        progressTimerTask = Task { [page] in
            guard let page else { return }
            while !Task.isCancelled {
                // Poll once every 1.5 seconds. Cheap enough for 0.7% CPU per
                // update on large documents because `stowerGetTopBlockIndex`
                // only walks blocks until the first visible one.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                if let top = await ReaderWebPageFactory.fetchTopBlockIndex(on: page) {
                    await MainActor.run { onReadingProgress?(top) }
                }
            }
        }
    }
}
