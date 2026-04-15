import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Converts a parsed `ReaderDocument` into a self-contained HTML document that
/// can be rendered in WKWebView. WebView rendering is the only way the app
/// scales to large articles — SwiftUI view descriptors become too expensive
/// past a few hundred blocks.
///
/// The generated HTML is a complete document with:
///   - inlined CSS from the user's `ReaderAppearanceSettings`
///   - semantic HTML5 elements (<h1>, <p>, <blockquote>, etc.)
///   - `data-block-index` attributes on each block so the TTS highlighter and
///     the scroll-position tracker can target blocks by stable index
///   - a small runtime JavaScript that exposes `stowerHighlight(index)`,
///     `stowerScrollToBlock(index)`, and posts reading progress events via
///     the `stowerReadingProgress` WKScriptMessageHandler
///
/// This is a pure function — no dependencies on the filesystem, database,
/// or main actor. Safe to call off the main thread.
public enum ReaderDocumentHTMLBuilder {
    public static func buildReaderHTML(
        item: SavedItem,
        document: ReaderDocument,
        appearance: ReaderAppearanceSettings,
        pageWidth: CGFloat = 10_000
    ) -> String {
        var html = String()
        html.reserveCapacity(document.blocks.count * 256)

        html += "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "  <meta charset=\"utf-8\">\n"
        html += "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=5\">\n"
        html += "  <meta name=\"color-scheme\" content=\"light dark\">\n"
        html += "  <title>\(escapeHTML(item.title))</title>\n"
        html += "  <style id=\"stower-reader-css\">\n"
        html += appearance.readerCSS(pageWidth: pageWidth)
        html += "\n  </style>\n"
        html += "  <style id=\"stower-runtime-css\">\n"
        html += runtimeCSS
        html += "\n  </style>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += "<article class=\"stower-article\">\n"

        // For YouTube documents the first body block is already a rich
        // thumbnail card, so skip the header's banner image to avoid
        // duplicating the same thumbnail twice in the reader.
        let suppressHero = isYouTubeDocument(document)
        html += renderHeader(item: item, suppressHero: suppressHero)

        for (index, block) in document.blocks.enumerated() {
            html += renderBlock(block, index: index)
            html += "\n"
        }

        html += "</article>\n"

        // Hidden plain-text dump so WKWebView's find-in-page can match
        // words inside documents whose visible content is non-textual —
        // primarily PDF items rendered as `.figure` blocks, where the
        // `<img>` tags carry no searchable text. The dump lives inside
        // the DOM (so it's findable) but is positioned outside the
        // viewport via `clip-path` and marked `aria-hidden` + `tabindex`
        // so screen readers and keyboard navigation skip it.
        if documentHasOnlyFigureBlocks(document),
           !item.content.isEmpty {
            html += "<div class=\"stower-search-index\" aria-hidden=\"true\" tabindex=\"-1\">\n"
            for paragraph in item.content.components(separatedBy: "\n\n") {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                html += "<p>\(escapeHTML(trimmed))</p>\n"
            }
            html += "</div>\n"
        }

        html += "<script>\n"
        html += runtimeJS
        html += "\n</script>\n"
        html += "</body>\n"
        html += "</html>\n"

        return html
    }

    /// Returns true when every block in the document is a `.figure` —
    /// i.e. the reader's visible content is entirely non-textual.
    /// Currently only PDF items produce this shape.
    private static func documentHasOnlyFigureBlocks(_ document: ReaderDocument) -> Bool {
        guard !document.blocks.isEmpty else {
            return false
        }
        return document.blocks.allSatisfy { block in
            if case .figure = block {
                return true
            }
            return false
        }
    }

    // MARK: - Header

    /// Returns true when the first body block is a YouTube video card — in
    /// that case the reader suppresses the header's hero image because the
    /// card itself shows the same thumbnail at full width.
    private static func isYouTubeDocument(_ document: ReaderDocument) -> Bool {
        if case let .video(media) = document.blocks.first,
           media.providerName == "YouTube" {
            return true
        }
        return false
    }

    private static func renderHeader(item: SavedItem, suppressHero: Bool = false) -> String {
        var html = "<header class=\"stower-header\" data-block-index=\"-1\">\n"

        if !suppressHero,
           let hero = item.heroImageURL, !hero.isEmpty, isSafeHTTPURL(hero) {
            html += "  <img class=\"stower-hero\" src=\"\(attrEscape(hero))\" alt=\"\">\n"
        }

        html += "  <h1 class=\"stower-title\">\(escapeHTML(item.title))</h1>\n"

        let metaPieces: [String] = {
            var pieces = [String]()
            if let siteName = item.siteName, !siteName.isEmpty {
                pieces.append("<span class=\"stower-site\">\(escapeHTML(siteName))</span>")
            }
            if let author = item.author, !author.isEmpty {
                pieces.append("<span class=\"stower-author\">by \(escapeHTML(author))</span>")
            }
            if let minutes = item.readingTimeMinutes {
                pieces.append("<span class=\"stower-reading-time\">\(minutes) min read</span>")
            }
            return pieces
        }()
        if !metaPieces.isEmpty {
            html += "  <div class=\"stower-meta\">\(metaPieces.joined(separator: " &middot; "))</div>\n"
        }

        if let source = item.sourceURL, let sourceURL = URL(string: source), let host = sourceURL.host {
            html += "  <a class=\"stower-source\" href=\"\(attrEscape(source))\">\(escapeHTML(host))</a>\n"
        }

        html += "  <hr class=\"stower-header-rule\">\n"
        html += "</header>\n"
        return html
    }

    // MARK: - Blocks

    private static func renderBlock(_ block: ReaderBlock, index: Int) -> String {
        let idAttr = "id=\"stower-block-\(index)\" data-block-index=\"\(index)\""
        switch block {
        case .paragraph(let inlines):
            return "<p \(idAttr)>\(renderInlines(inlines))</p>"

        case let .heading(level, inlines):
            let clamped = min(max(level, 1), 6)
            return "<h\(clamped) \(idAttr)>\(renderInlines(inlines))</h\(clamped)>"

        case let .list(ordered, items):
            let tag = ordered ? "ol" : "ul"
            var out = "<\(tag) \(idAttr)>"
            for item in items {
                out += "<li>\(renderInlines(item))</li>"
            }
            out += "</\(tag)>"
            return out

        case .blockquote(let inlines):
            return "<blockquote \(idAttr)><p>\(renderInlines(inlines))</p></blockquote>"

        case let .code(language, code):
            let langAttr: String
            if let language, !language.isEmpty {
                langAttr = " class=\"language-\(attrEscape(language))\""
            } else {
                langAttr = ""
            }
            return "<pre \(idAttr)><code\(langAttr)>\(escapeHTML(code))</code></pre>"

        case .figure(let media):
            return renderFigure(media: media, idAttr: idAttr)

        case .video(let media):
            return renderVideo(media: media, idAttr: idAttr)

        case .embed(let embed):
            return renderEmbed(embed, idAttr: idAttr)

        case .table(let markdown):
            return renderMarkdownTable(markdown, idAttr: idAttr)

        case .horizontalRule:
            return "<hr \(idAttr)>"

        case let .callout(title, inlines):
            var out = "<aside class=\"stower-callout\" \(idAttr)>"
            if let title, !title.isEmpty {
                out += "<h4>\(escapeHTML(title))</h4>"
            }
            out += "<p>\(renderInlines(inlines))</p>"
            out += "</aside>"
            return out
        }
    }

    /// Parses a GFM-style pipe table and emits an HTML `<table>`. Expected
    /// input is the format produced by `PDFIngestionClient`'s OCR pipeline:
    /// a header row, a separator row (`| --- | --- |`), and zero or more
    /// body rows. Any line that doesn't start with `|` is skipped.
    private static func renderMarkdownTable(_ markdown: String, idAttr: String) -> String {
        let rawLines = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("|") }

        guard !rawLines.isEmpty else {
            return "<div \(idAttr)></div>"
        }

        func parseRow(_ line: String) -> [String] {
            var trimmed = line
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        func isSeparator(_ cells: [String]) -> Bool {
            guard !cells.isEmpty else { return false }
            return cells.allSatisfy { cell in
                let t = cell.replacingOccurrences(of: ":", with: "")
                return !t.isEmpty && t.allSatisfy { $0 == "-" }
            }
        }

        var rows = rawLines.map(parseRow)
        guard !rows.isEmpty else { return "<div \(idAttr)></div>" }

        // The header row is the first line; the separator (if present)
        // immediately follows and is skipped.
        let header = rows.removeFirst()
        if let first = rows.first, isSeparator(first) {
            rows.removeFirst()
        }

        var html = "<table class=\"stower-table\" \(idAttr)>"
        html += "<thead><tr>"
        for cell in header {
            html += "<th>\(escapeHTML(cell))</th>"
        }
        html += "</tr></thead>"
        html += "<tbody>"
        for row in rows {
            html += "<tr>"
            for cell in row {
                html += "<td>\(escapeHTML(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    private static func renderFigure(media: MediaDescriptor, idAttr: String) -> String {
        let src = resolveMediaURL(media)
        guard !src.isEmpty else { return "" }
        let alt = media.altText.map(attrEscape) ?? ""
        var out = "<figure \(idAttr)>"
        out += "<img src=\"\(attrEscape(src))\" alt=\"\(alt)\" loading=\"lazy\">"
        if let caption = media.caption, !caption.isEmpty {
            out += "<figcaption>\(escapeHTML(caption))</figcaption>"
        }
        out += "</figure>"
        return out
    }

    private static func renderVideo(media: MediaDescriptor, idAttr: String) -> String {
        // Platform-specific branch: YouTube videos render as a tappable
        // thumbnail link card that opens the canonical watch URL in the
        // YouTube app / Safari via the existing navigation decider. No
        // inline playback — the read-later reading experience centers on
        // the title, description, and channel metadata.
        if media.providerName == "YouTube",
           let id = media.providerVideoID,
           YouTubeURLDetector.isValidVideoID(id) {
            return renderYouTubeCard(id: id, media: media, idAttr: idAttr)
        }

        let src = resolveMediaURL(media)
        guard !src.isEmpty else { return "" }
        var out = "<figure \(idAttr)>"
        var attrs = "controls preload=\"metadata\""
        if let poster = media.posterURL, !poster.isEmpty, isSafeHTTPURL(poster) {
            attrs += " poster=\"\(attrEscape(poster))\""
        }
        out += "<video src=\"\(attrEscape(src))\" \(attrs)></video>"
        if let caption = media.caption, !caption.isEmpty {
            out += "<figcaption>\(escapeHTML(caption))</figcaption>"
        }
        out += "</figure>"
        return out
    }

    /// Renders a YouTube video as a click-to-load facade. A `<button>` holds
    /// the cached thumbnail and a play badge; the runtime JS at the bottom of
    /// the document swaps it for a `youtube-nocookie.com/embed/…` iframe on
    /// tap so the video plays inline. A `<button>` (not an `<a>`) is used
    /// deliberately — `ReaderNavigationDecider` intercepts `.linkActivated`
    /// http(s) navigations and opens them in Safari, which we do NOT want
    /// here. Iframe subframe loads are not `.linkActivated`, so they fall
    /// through to `.allow` and play in place.
    private static func renderYouTubeCard(
        id: String,
        media: MediaDescriptor,
        idAttr: String
    ) -> String {
        // Detect shorts so we can render a 9:16 wrapper instead of 16:9.
        let isShorts: Bool
        if let sourceURL = URL(string: media.sourceURL),
           let match = YouTubeURLDetector.match(sourceURL),
           match.form == .shortsVertical {
            isShorts = true
        } else {
            isShorts = false
        }

        let figureClass = isShorts ? "stower-yt stower-yt-shorts" : "stower-yt"
        let poster = resolvePosterURL(media)
        let title = media.caption ?? "YouTube video"

        var out = "<figure class=\"\(figureClass)\" \(idAttr)>"
        out += "<div class=\"stower-yt-wrap\">"
        out += "<button type=\"button\" class=\"stower-yt-facade\""
        out += " data-yt-id=\"\(attrEscape(id))\""
        out += " aria-label=\"Play YouTube video: \(attrEscape(title))\">"
        if !poster.isEmpty {
            out += "<img class=\"stower-yt-poster\" src=\"\(attrEscape(poster))\" alt=\"\" loading=\"lazy\">"
        }
        out += "<span class=\"stower-yt-play\" aria-hidden=\"true\"></span>"
        out += "</button>"
        out += "</div>"
        out += "</figure>"
        return out
    }

    /// Returns the best URL for a media item's poster/thumbnail, preferring
    /// the pre-downloaded local file if it exists. Mirrors `resolveMediaURL`
    /// but operates on `posterLocalURL` / `posterURL`.
    private static func resolvePosterURL(_ media: MediaDescriptor) -> String {
        if let local = media.posterLocalURL,
           !local.isEmpty,
           FileManager.default.fileExists(atPath: local) {
            return URL(fileURLWithPath: local).absoluteString
        }
        if let remote = media.posterURL, isSafeHTTPURL(remote) {
            return remote
        }
        return ""
    }

    private static func renderEmbed(_ embed: EmbedDescriptor, idAttr: String) -> String {
        // Use a custom `stower-embed://` scheme so the reader navigation
        // decider can intercept the tap and present the inline embed sheet
        // (mirroring the native EmbedCard "Open Inline" affordance).
        let safeURL = isSafeHTTPURL(embed.embedURL) ? embed.embedURL : ""
        let encoded = safeURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var out = "<aside class=\"stower-embed\" \(idAttr)>"
        out += "<div class=\"stower-embed-provider\">\(escapeHTML(embed.provider))</div>"
        if !safeURL.isEmpty {
            out += "<a class=\"stower-embed-inline\" href=\"stower-embed://\(encoded)\">Open Inline</a>"
            out += " "
            out += "<a class=\"stower-embed-source\" href=\"\(attrEscape(safeURL))\">Open Source</a>"
        }
        out += "</aside>"
        return out
    }

    // MARK: - Inlines

    private static func renderInlines(_ inlines: [ReaderInline]) -> String {
        var out = String()
        out.reserveCapacity(inlines.count * 16)
        for inline in inlines {
            switch inline {
            case .text(let value):
                out += escapeHTML(value)

            case .lineBreak:
                out += "<br>"

            case let .link(label, url):
                if isSafeLinkURL(url) {
                    out += "<a href=\"\(attrEscape(url))\" target=\"_blank\" rel=\"noopener noreferrer\">\(escapeHTML(label))</a>"
                } else {
                    // Unsafe scheme — fall back to plain text to avoid
                    // honoring `javascript:`, `data:`, or custom schemes
                    // that slipped past extraction.
                    out += escapeHTML(label)
                }

            case .emphasis(let value):
                out += "<em>\(escapeHTML(value))</em>"

            case .strong(let value):
                out += "<strong>\(escapeHTML(value))</strong>"

            case .code(let value):
                out += "<code>\(escapeHTML(value))</code>"

            case .strikethrough(let value):
                out += "<s>\(escapeHTML(value))</s>"
            }
        }
        return out
    }

    // MARK: - Helpers

    /// Returns the best URL string for a media descriptor, preferring the
    /// pre-downloaded local file if it exists.
    ///
    /// Special case: PDF page images emitted by `PDFIngestionClient` use a
    /// `stower://pdf-page/N` marker in their `sourceURL`. For these we
    /// return the bare filename (e.g. `"pdf-page-3.jpg"`), which renders
    /// as a **relative** `<img src="pdf-page-3.jpg">` in the HTML. The
    /// reader's structured-HTML `LocalArchiveServer` serves that path out
    /// of its per-view scratch directory, which has symlinks pointing at
    /// the real images in `StowerArchive/{itemID}/`. This keeps the PDF
    /// page images inside the HTML's same-origin context — loading
    /// `file://` URLs from an `http://localhost` document is blocked by
    /// WKWebView, so the relative-URL indirection is load-bearing.
    private static func resolveMediaURL(_ media: MediaDescriptor) -> String {
        if media.sourceURL.hasPrefix("stower://pdf-page/"),
           let local = media.localURL, !local.isEmpty {
            return URL(fileURLWithPath: local).lastPathComponent
        }
        if let local = media.localURL, !local.isEmpty, FileManager.default.fileExists(atPath: local) {
            return URL(fileURLWithPath: local).absoluteString
        }
        return isSafeHTTPURL(media.sourceURL) ? media.sourceURL : ""
    }

    private static func isSafeHTTPURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
            return false
        }
        return scheme == "https" || scheme == "http"
    }

    /// Allow only http(s), mailto, and fragment-local URLs for inline links.
    private static func isSafeLinkURL(_ url: String) -> Bool {
        if url.hasPrefix("#") {
            return true
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
            return false
        }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }

    // MARK: - Escaping

    /// Full HTML text escape: `&`, `<`, `>`, `"`, `'`.
    static func escapeHTML(_ s: String) -> String {
        var result = String()
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&":
                result += "&amp;"
            case "<":
                result += "&lt;"
            case ">":
                result += "&gt;"
            case "\"":
                result += "&quot;"
            case "'":
                result += "&#39;"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Attribute-context escape — same as HTML escape; we use it distinctly so
    /// the intent is clear at call sites.
    static func attrEscape(_ s: String) -> String {
        escapeHTML(s)
    }

    // MARK: - Runtime CSS

    private static let runtimeCSS = """
    .stower-article { padding-bottom: 120px; }
    .stower-header { margin-bottom: 28px; }
    .stower-hero {
      width: 100%;
      max-height: 400px;
      object-fit: cover;
      border-radius: 14px;
      margin-bottom: 16px;
      display: block;
    }
    .stower-title {
      font-weight: 700;
      line-height: 1.15;
      margin: 0 0 14px;
    }
    .stower-meta {
      font-size: 0.9em;
      opacity: 0.72;
      margin-bottom: 4px;
    }
    .stower-source {
      font-size: 0.82em;
      opacity: 0.6;
      text-decoration: none;
    }
    .stower-header-rule {
      border: none;
      border-top: 1px solid currentColor;
      opacity: 0.12;
      margin-top: 18px;
      margin-bottom: 0;
    }
    figure { margin: 28px 0; }
    /* PDF page image figures — rasterized pages rendered inline. One
       <figure> per page. Tighter vertical margin than article figures
       so adjacent pages read as a contiguous document, and a subtle
       1px border so each page is visually bounded against the reader's
       background. The figcaption ("Page N of M") is present for
       accessibility but visually hidden — real PDF pages already
       carry their own page numbering. */
    figure:has(img[src^="pdf-page-"]) {
      margin: 16px 0;
    }
    figure img[src^="pdf-page-"] {
      width: 100%;
      height: auto;
      border-radius: 4px;
      box-shadow: 0 1px 4px rgba(0, 0, 0, 0.12);
    }
    figure:has(img[src^="pdf-page-"]) figcaption {
      position: absolute;
      width: 1px;
      height: 1px;
      overflow: hidden;
      clip: rect(0 0 0 0);
    }
    /* Hidden text index for WKWebView find-in-page on PDF items.
       Content lives in the normal document flow (which is the only
       reliable way WebKit's find-in-page picks up text — anything
       with display:none, visibility:hidden, or an off-viewport
       absolute position is excluded from the find index). Visual
       invisibility comes from transparent color + 1px font + 0
       line-height, so the block collapses to near-zero height
       without WebKit thinking it's hidden. Marked aria-hidden so
       screen readers skip the duplicate content, and user-select:none
       so rubber-band selection doesn't accidentally grab it. */
    .stower-search-index {
      color: transparent;
      font-size: 1px;
      line-height: 0;
      user-select: none;
      -webkit-user-select: none;
      pointer-events: none;
    }
    .stower-search-index p {
      margin: 0;
      padding: 0;
    }
    figure img, figure video {
      display: block;
      max-width: 100%;
      height: auto;
      border-radius: 10px;
      margin: 0 auto;
    }
    figcaption {
      font-size: 0.84em;
      opacity: 0.72;
      text-align: center;
      margin-top: 8px;
    }
    .stower-embed, .stower-callout {
      border: 1px solid currentColor;
      border-radius: 12px;
      padding: 14px 16px;
      margin: 20px 0;
      opacity: 0.95;
    }
    .stower-embed-provider { font-weight: 600; margin-bottom: 4px; }
    .stower-embed a { margin-right: 12px; }
    .stower-callout h4 { margin: 0 0 8px; font-weight: 600; }
    .stower-table-markdown pre {
      white-space: pre-wrap;
      word-break: break-word;
    }
    table.stower-table {
      border-collapse: collapse;
      width: 100%;
      margin: 20px 0;
      font-size: 0.92em;
    }
    table.stower-table th,
    table.stower-table td {
      border: 1px solid currentColor;
      padding: 8px 12px;
      text-align: left;
      vertical-align: top;
      opacity: 0.92;
    }
    table.stower-table thead th {
      font-weight: 600;
      background: rgba(128, 128, 128, 0.12);
    }
    table.stower-table tbody tr:nth-child(even) td {
      background: rgba(128, 128, 128, 0.06);
    }
    hr {
      border: none;
      border-top: 1px solid currentColor;
      opacity: 0.16;
      margin: 32px auto;
      width: 40%;
    }
    blockquote {
      margin: 20px 0;
    }
    .stower-highlight {
      background: rgba(255, 220, 0, 0.28);
      border-radius: 6px;
      transition: background 0.18s ease-out;
    }
    @media (prefers-color-scheme: dark) {
      .stower-highlight { background: rgba(255, 220, 0, 0.2); }
    }
    .stower-yt { margin: 28px 0; }
    .stower-yt-wrap {
      position: relative;
      width: 100%;
      aspect-ratio: 16 / 9;
      border-radius: 12px;
      overflow: hidden;
      background: #000;
    }
    .stower-yt-shorts .stower-yt-wrap {
      aspect-ratio: 9 / 16;
      max-width: 420px;
      margin: 0 auto;
    }
    .stower-yt-wrap iframe,
    .stower-yt-wrap .stower-yt-facade {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      border: 0;
    }
    .stower-yt-facade {
      padding: 0;
      margin: 0;
      background: transparent;
      cursor: pointer;
      display: block;
    }
    .stower-yt-poster {
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: block;
    }
    .stower-yt-play {
      position: absolute;
      top: 50%;
      left: 50%;
      width: 76px;
      height: 76px;
      transform: translate(-50%, -50%);
      border-radius: 50%;
      background: #ff0000;
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.35);
      pointer-events: none;
    }
    .stower-yt-play::after {
      content: "";
      position: absolute;
      top: 50%;
      left: 56%;
      transform: translate(-50%, -50%);
      border-style: solid;
      border-width: 14px 0 14px 22px;
      border-color: transparent transparent transparent #fff;
    }
    """

    // MARK: - Runtime JS

    /// The in-page runtime. Exposes three functions on `window`:
    ///   - `stowerHighlight(index)` — add/remove the TTS highlight class and
    ///     scroll into view when the block is off-screen.
    ///   - `stowerScrollToBlock(index)` — jump to a block instantly (used for
    ///     reading-position restoration on load).
    ///   - `stowerGetTopBlockIndex()` — returns the `data-block-index` of the
    ///     topmost visible block. Swift polls this periodically via
    ///     `WebPage.callJavaScript` to implement reading-progress persistence.
    ///     Uses polling rather than script message handlers so we stay within
    ///     the iOS 18 SwiftUI `WebPage` API surface.
    private static let runtimeJS = """
    (function() {
      var currentHighlight = null;
      var horizontalLockScheduled = false;

      function lockHorizontalScroll() {
        if (window.scrollX !== 0) {
          window.scrollTo(0, window.scrollY);
        }
      }

      function scheduleHorizontalLock() {
        if (horizontalLockScheduled) { return; }
        horizontalLockScheduled = true;
        window.requestAnimationFrame(function() {
          horizontalLockScheduled = false;
          lockHorizontalScroll();
        });
      }

      window.addEventListener('scroll', scheduleHorizontalLock, { passive: true });
      window.addEventListener('touchmove', scheduleHorizontalLock, { passive: true });
      window.addEventListener('load', lockHorizontalScroll, { once: true });

      window.stowerHighlight = function(index) {
        if (currentHighlight) {
          currentHighlight.classList.remove('stower-highlight');
          currentHighlight = null;
        }
        if (index == null || index < 0) return;
        var el = document.getElementById('stower-block-' + index);
        if (!el) return;
        el.classList.add('stower-highlight');
        currentHighlight = el;
        var rect = el.getBoundingClientRect();
        if (rect.top < 60 || rect.bottom > window.innerHeight - 60) {
          el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      };

      window.stowerClearHighlight = function() { window.stowerHighlight(null); };

      window.stowerScrollToBlock = function(index) {
        if (index == null || index < 0) return;
        var el = document.getElementById('stower-block-' + index);
        if (!el) return;
        // Instant jump, no smooth scrolling on restore.
        el.scrollIntoView({ behavior: 'auto', block: 'start' });
      };

      // Compute and return the top-most visible block's data-block-index.
      // Returns -1 if no blocks are found. Swift polls this.
      window.stowerGetTopBlockIndex = function() {
        var blocks = document.querySelectorAll('[data-block-index]');
        var topY = 80; // offset to favour "the block you're reading", not one above
        for (var i = 0; i < blocks.length; i++) {
          var r = blocks[i].getBoundingClientRect();
          if (r.bottom >= topY) {
            var idx = parseInt(blocks[i].getAttribute('data-block-index'), 10);
            if (!isNaN(idx) && idx >= 0) { return idx; }
          }
        }
        return -1;
      };

      // YouTube facade → iframe swap. Delegated click handler so the swap
      // works for any facade rendered by the builder. The video ID is
      // re-validated against the same 11-char charset used at render time
      // before it is interpolated into the iframe src.
      document.addEventListener('click', function(e) {
        var btn = e.target.closest && e.target.closest('.stower-yt-facade');
        if (!btn) return;
        e.preventDefault();
        var id = btn.getAttribute('data-yt-id');
        if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return;
        var iframe = document.createElement('iframe');
        iframe.src = 'https://www.youtube-nocookie.com/embed/' + id + '?autoplay=1&rel=0&modestbranding=1&playsinline=1';
        iframe.setAttribute('allow', 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; fullscreen');
        iframe.setAttribute('allowfullscreen', '');
        iframe.setAttribute('loading', 'lazy');
        iframe.setAttribute('referrerpolicy', 'no-referrer-when-downgrade');
        btn.replaceWith(iframe);
      });
    })();
    """
}
