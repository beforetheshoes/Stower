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
    let onSwitchToNative: (() -> Void)?
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
        onSwitchToNative: (() -> Void)? = nil,
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
        self.onSwitchToNative = onSwitchToNative
        self.onReadingProgress = onReadingProgress
        self.onOpenInlineEmbed = onOpenInlineEmbed
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let onSwitchToNative {
                HStack {
                    Spacer()
                    Button("Switch to Reader Version") {
                        onSwitchToNative()
                    }
                    .font(.caption)
                    .foregroundStyle(appearance.secondaryTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(appearance.surfaceColor)
            }

            if let page {
                WebView(page)
                    .webViewContentBackground(.hidden)
            }
        }
        .background(appearance.backgroundColor)
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
                // Structured / HTML-fallback path: the HTML is already a
                // fully-styled document from ReaderDocumentHTMLBuilder.
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

    /// Prepares archive content off the main actor: patches HTML, injects CSS, starts server.
    private nonisolated static func prepareArchive(
        html: String,
        sourceURL: String?,
        itemID: UUID,
        appearance: ReaderAppearanceSettings
    ) async -> (URL?, LocalArchiveServer?) {
        if !html.isEmpty {
            AssetArchiver.refreshIndexHTML(for: itemID, sourceHTML: html)
        } else {
            AssetArchiver.refreshIndexHTML(for: itemID)
        }

        let css = appearance.readerOverlayCSS(pageWidth: 10_000)
        AssetArchiver.injectReaderCSS(css, for: itemID)

        let archiveDir = AssetArchiver.archiveDirectory(for: itemID)
        let articlePath = sourceURL.flatMap(URL.init(string:))?.path ?? "/"

        let server = LocalArchiveServer(archiveDir: archiveDir, articlePath: articlePath)
        guard let port = try? await server.start() else { return (nil, nil) }

        let loadURL = URL(string: "http://localhost:\(port)\(articlePath)")!
        return (loadURL, server)
    }

    // MARK: - Live CSS updates

    @MainActor
    private func updateCSS(_ appearance: ReaderAppearanceSettings) {
        guard let page else { return }

        let css: String
        if isWebViewFormat && AssetArchiver.archiveExists(for: itemID) {
            css = appearance.readerOverlayCSS(pageWidth: 10_000)
        } else {
            css = appearance.readerCSS(pageWidth: 10_000)
        }

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
