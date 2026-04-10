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

        html += renderHeader(item: item)

        for (index, block) in document.blocks.enumerated() {
            html += renderBlock(block, index: index)
            html += "\n"
        }

        html += "</article>\n"
        html += "<script>\n"
        html += runtimeJS
        html += "\n</script>\n"
        html += "</body>\n"
        html += "</html>\n"

        return html
    }

    // MARK: - Header

    private static func renderHeader(item: SavedItem) -> String {
        var html = "<header class=\"stower-header\" data-block-index=\"-1\">\n"

        if let hero = item.heroImageURL, !hero.isEmpty, isSafeHTTPURL(hero) {
            html += "  <img class=\"stower-hero\" src=\"\(attrEscape(hero))\" alt=\"\">\n"
        }

        html += "  <h1 class=\"stower-title\">\(escapeHTML(item.title))</h1>\n"

        var metaPieces: [String] = []
        if let siteName = item.siteName, !siteName.isEmpty {
            metaPieces.append("<span class=\"stower-site\">\(escapeHTML(siteName))</span>")
        }
        if let author = item.author, !author.isEmpty {
            metaPieces.append("<span class=\"stower-author\">by \(escapeHTML(author))</span>")
        }
        if let minutes = item.readingTimeMinutes {
            metaPieces.append("<span class=\"stower-reading-time\">\(minutes) min read</span>")
        }
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

        case .heading(let level, let inlines):
            let clamped = min(max(level, 1), 6)
            return "<h\(clamped) \(idAttr)>\(renderInlines(inlines))</h\(clamped)>"

        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            var out = "<\(tag) \(idAttr)>"
            for item in items {
                out += "<li>\(renderInlines(item))</li>"
            }
            out += "</\(tag)>"
            return out

        case .blockquote(let inlines):
            return "<blockquote \(idAttr)><p>\(renderInlines(inlines))</p></blockquote>"

        case .code(let language, let code):
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
            // Proper GFM table parsing is a follow-up. For now, emit the raw
            // markdown in a preformatted block so it's legible.
            return "<div class=\"stower-table-markdown\" \(idAttr)><pre>\(escapeHTML(markdown))</pre></div>"

        case .horizontalRule:
            return "<hr \(idAttr)>"

        case .callout(let title, let inlines):
            var out = "<aside class=\"stower-callout\" \(idAttr)>"
            if let title, !title.isEmpty {
                out += "<h4>\(escapeHTML(title))</h4>"
            }
            out += "<p>\(renderInlines(inlines))</p>"
            out += "</aside>"
            return out
        }
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

            case .link(let label, let url):
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
    /// pre-downloaded local file if it exists. When served through a local
    /// HTTP archive server the `file://` URL is translated server-side.
    private static func resolveMediaURL(_ media: MediaDescriptor) -> String {
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
        if url.hasPrefix("#") { return true }
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
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.unicodeScalars.append(scalar)
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
    })();
    """
}
