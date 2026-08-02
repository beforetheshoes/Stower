import Foundation
import SwiftSoup

struct ParsedBlocks {
    var blocks = [ReaderBlock]()
    var media = [MediaDescriptor]()
    var embeds = [EmbedDescriptor]()
}

func parseBlocks(root: Element, baseURL: URL) throws -> ParsedBlocks {
    let cleanedDoc = try SwiftSoup.parseBodyFragment(try root.outerHtml(), baseURL.absoluteString)
    guard let body = cleanedDoc.body() else {
        return ParsedBlocks(blocks: [], media: [], embeds: [])
    }

    let toRemove = try body.select(
        "script, style, svg, canvas, template, nav, footer, form, button, [aria-hidden=true], [hidden], .sr-only, .visually-hidden, .screen-reader-text, .sidebar, .related, .share, .comments"
    )
    try toRemove.remove()

    // `header` and `aside` used to be removed outright. That also deleted the
    // article's own headline block (many sites wrap the h1 + standfirst in a
    // `<header>` inside `<article>`) and every pull quote, sidenote and
    // callout. Only drop the ones that are actually site chrome.
    let chrome = try body.select(
        """
        header[role=banner], aside[role=navigation], aside[role=complementary], \
        header[class*=site], header[class*=global], header[class*=masthead], \
        header[class*=nav], aside[class*=nav], aside[class*=sidebar], \
        aside[class*=related], aside[class*=promo], aside[class*=newsletter], \
        aside[class*=subscribe], aside[class*=advert]
        """
    )
    try chrome.remove()

    // Remove permalink/headerlink anchors commonly added next to headings by
    // static site generators (MkDocs, Sphinx, Hugo, Jekyll, Docusaurus, etc.).
    // These typically render as "¶" or "#" and link back to the heading's anchor.
    let anchorLinks = try body.select(
        "a.headerlink, a.anchor, a.anchorlink, a.anchor-link, a.anchor_link, a.permalink, a.heading-link, a.heading_link, a.hash-link, a.header-link, .headerlink, .anchorjs-link"
    )
    try anchorLinks.remove()
    let headingAnchors = try body.select("h1 > a[href^=#], h2 > a[href^=#], h3 > a[href^=#], h4 > a[href^=#], h5 > a[href^=#], h6 > a[href^=#]")
    try headingAnchors.remove()

    var blocks = [ReaderBlock]()
    var media = [MediaDescriptor]()
    var embeds = [EmbedDescriptor]()

    for childNode in body.getChildNodes() {
        guard let child = childNode as? Element else { continue }
        let parsed = try parseBlock(child)
        blocks.append(contentsOf: parsed.blocks)
        media.append(contentsOf: parsed.media)
        embeds.append(contentsOf: parsed.embeds)
    }

    if blocks.isEmpty {
        let descendantFallback = try parseFallbackDescendants(body)
        blocks = descendantFallback.blocks
        media.append(contentsOf: descendantFallback.media)
        embeds.append(contentsOf: descendantFallback.embeds)
    }

    if blocks.isEmpty {
        let fallback = cleanText((try? body.text()) ?? "")
        if !fallback.isEmpty {
            blocks = splitLongParagraph(fallback).map { .paragraph([.text($0)]) }
        }
    }

    return ParsedBlocks(blocks: blocks, media: media, embeds: embeds)
}

func parseBlock(_ element: Element) throws -> ParsedBlocks {
    let tag = element.tagName().lowercased()

    switch tag {
    case "h1", "h2", "h3", "h4", "h5", "h6":
        let level = Int(String(tag.dropFirst())) ?? 1
        let inlines = try parseInlines(element)
        return ParsedBlocks(blocks: inlines.isEmpty ? [] : [.heading(level: level, inlines: inlines)], media: [], embeds: [])

    case "p":
        var media = [MediaDescriptor]()
        var embeds = [EmbedDescriptor]()
        var mediaBlocks = [ReaderBlock]()

        let mediaNodes = try element.select("img,picture,video,iframe,figure").array()
        for mediaNode in mediaNodes {
            let parsed = try parseBlock(mediaNode)
            mediaBlocks.append(contentsOf: parsed.blocks)
            media.append(contentsOf: parsed.media)
            embeds.append(contentsOf: parsed.embeds)
        }

        // Parse the prose from a copy with the media subtrees removed. Parsing
        // the original would pull each `<figcaption>` into the paragraph text
        // *and* emit it again as the figure's caption, so every captioned
        // image inside a paragraph printed its caption twice.
        let inlines: [ReaderInline]
        if mediaNodes.isEmpty {
            inlines = try parseInlines(element)
        } else {
            let prose = element.copy() as! Element
            try prose.select("img,picture,video,iframe,figure").remove()
            inlines = try parseInlines(prose)
        }

        var blocks: [ReaderBlock] = inlines.isEmpty ? [] : [.paragraph(inlines)]
        blocks.append(contentsOf: mediaBlocks)

        return ParsedBlocks(blocks: dedupeBlocks(blocks), media: dedupeMedia(media), embeds: dedupeEmbeds(embeds))

    case "ul", "ol":
        let listItems = try parseListItems(element)
        return ParsedBlocks(blocks: listItems.isEmpty ? [] : [.list(ordered: tag == "ol", items: listItems)], media: [], embeds: [])

    case "dl":
        // Description lists render as a list of "term — definition" items.
        // Without this case they fall through to `default`, which emits one
        // paragraph per <dt>/<dd> and loses the pairing entirely.
        let items = try parseDescriptionList(element)
        return ParsedBlocks(blocks: items.isEmpty ? [] : [.list(ordered: false, items: items)], media: [], embeds: [])

    case "table":
        guard let markdown = try markdownTable(from: element) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.table(markdown: markdown)], media: [], embeds: [])

    case "blockquote":
        let inlines = try parseInlines(element)
        return ParsedBlocks(blocks: inlines.isEmpty ? [] : [.blockquote(inlines)], media: [], embeds: [])

    case "pre":
        // Code must keep its line breaks and indentation. `cleanText` (and
        // SwiftSoup's default `text()`) collapse every run of whitespace to a
        // single space, which turned every code block in the reader into one
        // unreadable line that had to be scrolled horizontally.
        let language = codeLanguage(from: element)
        let code = preformattedText(element)
        if code.isEmpty {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.code(language: language, code: code)], media: [], embeds: [])

    case "img":
        guard let image = try imageDescriptor(element, captionHint: nil) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])

    case "picture":
        guard let image = try pictureDescriptor(element) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])

    case "noscript":
        let raw = cleanText((try? element.html()) ?? "")
        guard !raw.isEmpty else { return ParsedBlocks(blocks: [], media: [], embeds: []) }
        let fragment = try SwiftSoup.parseBodyFragment(raw)
        guard let fragmentBody = fragment.body() else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        var combined = ParsedBlocks(blocks: [], media: [], embeds: [])
        for node in fragmentBody.getChildNodes() {
            guard let child = node as? Element else { continue }
            let parsed = try parseBlock(child)
            combined.blocks.append(contentsOf: parsed.blocks)
            combined.media.append(contentsOf: parsed.media)
            combined.embeds.append(contentsOf: parsed.embeds)
        }
        return combined

    case "video":
        guard let video = try videoDescriptor(element) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.video(media: video)], media: [video], embeds: [])

    case "iframe":
        guard let embed = try embedDescriptor(element) else {
            return ParsedBlocks(blocks: [], media: [], embeds: [])
        }
        return ParsedBlocks(blocks: [.embed(embed)], media: [], embeds: [embed])

    case "hr":
        return ParsedBlocks(blocks: [.horizontalRule], media: [], embeds: [])

    case "figure":
        let caption = nonEmpty(try? element.select("figcaption").first()?.text())
        if let imageElement = try element.select("img").first(),
           let image = try imageDescriptor(imageElement, captionHint: caption) {
            return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])
        }
        if let pictureElement = try element.select("picture").first(),
           let image = try pictureDescriptor(pictureElement, captionHint: caption) {
            return ParsedBlocks(blocks: [.figure(media: image)], media: [image], embeds: [])
        }
        return ParsedBlocks(blocks: [], media: [], embeds: [])

    default:
        var combined = ParsedBlocks(blocks: [], media: [], embeds: [])
        for node in element.getChildNodes() {
            guard let child = node as? Element else { continue }
            let parsed = try parseBlock(child)
            combined.blocks.append(contentsOf: parsed.blocks)
            combined.media.append(contentsOf: parsed.media)
            combined.embeds.append(contentsOf: parsed.embeds)
        }
        if combined.blocks.isEmpty {
            let ownText = cleanText(element.ownText())
            if !ownText.isEmpty {
                combined.blocks = [.paragraph([.text(ownText)])]
            }
        }
        return combined
    }
}

/// Top-level inline parser. Runs the recursive extraction, then trims
/// leading/trailing whitespace from the outermost segments so the
/// containing paragraph/heading/list item doesn't start or end with a stray
/// space. Callers that consume inline lists as block content (paragraph,
/// heading, list item, blockquote, callout body) should call this.
func parseInlines(_ element: Element) throws -> [ReaderInline] {
    try trimInlineEdges(parseInlinesRaw(element))
}

/// Recursive worker that does NOT trim outer whitespace — used for both
/// the top-level call and for recursing into unknown wrapper tags like
/// `<span>`. If this trimmed edges it would delete the boundary space that
/// separates the wrapper's inner content from its siblings (e.g. the
/// leading space on `<span> until the user...</span>` when the span
/// follows an `<a>` in the same paragraph).
func parseInlinesRaw(_ element: Element) throws -> [ReaderInline] {
    var inlines = [ReaderInline]()

    for node in element.getChildNodes() {
        if let textNode = node as? TextNode {
            // Use cleanInlineText so boundary whitespace survives — this is
            // what keeps `"word "` separate from a following `<a>link</a>`.
            let text = cleanInlineText(textNode.text())
            if !text.isEmpty {
                inlines.append(.text(text))
            }
            continue
        }

        guard let child = node as? Element else { continue }
        let tag = child.tagName().lowercased()

        switch tag {
        case "a":
            let rawHref = nonEmpty(try? child.attr("href")) ?? ""
            let rawClass = ((try? child.className()) ?? "").lowercased()
            // Skip permalink/anchor links that slipped past the pre-filter.
            let anchorClassHints = ["headerlink", "anchor", "permalink", "heading-link", "hash-link"]
            let looksLikeAnchor = anchorClassHints.contains(where: rawClass.contains)
            let isFragmentOnly = rawHref.hasPrefix("#")
            let extracted = extractInlineElementText(child)
            let label = extracted.label
            // Symbol-only labels (¶, #, §) almost always indicate permalinks.
            let symbolOnly = !label.isEmpty &&
                label.unicodeScalars.allSatisfy { !$0.properties.isAlphabetic && !CharacterSet.decimalDigits.contains($0) }
            if looksLikeAnchor || (isFragmentOnly && (label.isEmpty || symbolOnly || label.count <= 2)) {
                continue
            }
            let href = nonEmpty(try? child.attr("abs:href")) ?? rawHref
            if !label.isEmpty, !href.isEmpty {
                appendWithBoundarySpaces(&inlines, extracted: extracted, inline: .link(label: label, url: href))
            } else if !label.isEmpty {
                appendWithBoundarySpaces(&inlines, extracted: extracted, inline: .text(label))
            }

        case "em", "i":
            let extracted = extractInlineElementText(child)
            if !extracted.label.isEmpty {
                appendWithBoundarySpaces(&inlines, extracted: extracted, inline: .emphasis(extracted.label))
            }

        case "strong", "b":
            let extracted = extractInlineElementText(child)
            if !extracted.label.isEmpty {
                appendWithBoundarySpaces(&inlines, extracted: extracted, inline: .strong(extracted.label))
            }

        case "code":
            let extracted = extractInlineElementText(child)
            if !extracted.label.isEmpty {
                appendWithBoundarySpaces(&inlines, extracted: extracted, inline: .code(extracted.label))
            }

        case "del", "s":
            let extracted = extractInlineElementText(child)
            if !extracted.label.isEmpty {
                appendWithBoundarySpaces(&inlines, extracted: extracted, inline: .strikethrough(extracted.label))
            }

        case "br":
            // `.text("\n")` renders as a literal newline in the generated
            // HTML, which the browser collapses to a space — poetry, verse,
            // addresses and lyrics all ran together. `.lineBreak` is rendered
            // as a real `<br>` by `ReaderDocumentHTMLBuilder`.
            inlines.append(.lineBreak)

        default:
            // Recurse through the *raw* worker so we don't strip the
            // boundary whitespace off the wrapper's edges. Concrete
            // example: `<span> until the user...</span>` — the leading
            // space must survive for the paragraph render to spell
            // correctly.
            inlines.append(contentsOf: try parseInlinesRaw(child))
        }
    }

    return mergeTextInlines(inlines)
}

func mergeTextInlines(_ inlines: [ReaderInline]) -> [ReaderInline] {
    var merged = [ReaderInline]()
    for inline in inlines {
        if case .text(let current) = inline,
           case .text(let previous)? = merged.last {
            merged.removeLast()
            // Boundary spaces are already preserved on the individual text
            // segments by `cleanInlineText`, so simple concatenation is
            // correct. Collapse any double-space that happens at the seam
            // when both neighbours carried an edge space.
            let joined = (previous + current)
                .replacingOccurrences(of: "  ", with: " ")
            merged.append(.text(joined))
        } else {
            merged.append(inline)
        }
    }
    return merged
}

/// Extracted text content of an inline formatting element, along with flags
/// indicating whether the raw source had leading/trailing whitespace. Used
/// by `parseInlines` to decide whether to emit boundary `.text(" ")` segments
/// around a link/strong/em/code/strikethrough inline.
struct ExtractedInlineText {
    var label: String
    var hasLeadingSpace: Bool
    var hasTrailingSpace: Bool
}

/// Pulls the text content of an inline formatting element without losing
/// the boundary whitespace. SwiftSoup's `Element.text()` trims by default,
/// so `<a>requests </a>until` would come back as `"requests"` with the
/// trailing space silently dropped — and then `.link("requests")` would
/// render smooshed against the following `"until"` TextNode. Passing
/// `trimAndNormaliseWhitespace: false` returns the raw text, which
/// `cleanInlineText` then collapses while preserving a single leading/
/// trailing space.
func extractInlineElementText(_ element: Element) -> ExtractedInlineText {
    let raw = cleanInlineText((try? element.text(trimAndNormaliseWhitespace: false)) ?? "")
    return ExtractedInlineText(
        label: raw.trimmingCharacters(in: .whitespacesAndNewlines),
        hasLeadingSpace: raw.hasPrefix(" "),
        hasTrailingSpace: raw.hasSuffix(" ")
    )
}

/// Appends an inline formatting segment to the parse buffer, emitting
/// `.text(" ")` boundary segments before/after when the source element had
/// leading/trailing whitespace inside its tag (e.g. `<a>link </a>`). These
/// boundary segments merge with adjacent TextNode `.text(...)` inlines in
/// `mergeTextInlines`, so they end up as a single space in the final output.
func appendWithBoundarySpaces(
    _ inlines: inout [ReaderInline],
    extracted: ExtractedInlineText,
    inline: ReaderInline
) {
    if extracted.hasLeadingSpace { inlines.append(.text(" ")) }
    inlines.append(inline)
    if extracted.hasTrailingSpace { inlines.append(.text(" ")) }
}

/// Strip leading whitespace from the first text segment and trailing
/// whitespace from the last text segment of an inline list, so that
/// paragraphs/headings/list items don't start or end with a stray space.
/// Drops empty `.text("")` segments that result.
func trimInlineEdges(_ inlines: [ReaderInline]) -> [ReaderInline] {
    var result = inlines
    if case .text(let first)? = result.first {
        let trimmed = String(first.drop { $0 == " " })
        if trimmed.isEmpty {
            result.removeFirst()
        } else {
            result[0] = .text(trimmed)
        }
    }
    if case .text(let last)? = result.last {
        let trimmed = String(last.reversed().drop { $0 == " " }.reversed())
        if trimmed.isEmpty {
            result.removeLast()
        } else {
            result[result.count - 1] = .text(trimmed)
        }
    }
    return result
}

// MARK: - Lists

func isListTag(_ tag: String) -> Bool {
    let lowered = tag.lowercased()
    return lowered == "ul" || lowered == "ol"
}

/// Parses the direct `<li>` children of a `<ul>`/`<ol>`.
///
/// Two things the naive `select("> li").map(parseInlines)` got wrong:
///
///  * A nested `<ul>`/`<ol>` inside an `<li>` was flattened into the parent
///    item's inline run with no separator at all, so "Fruit / Apple / Pear"
///    came out as the single item "FruitApplePear". Nested items are now
///    lifted into the same list as their own entries, prefixed so the
///    hierarchy is still legible.
///  * An `<li>` containing several block children (`<p>`, `<div>`) had them
///    concatenated with no space, fusing the last word of one paragraph to
///    the first word of the next.
func parseListItems(_ element: Element) throws -> [[ReaderInline]] {
    var items = [[ReaderInline]]()

    for item in try element.select("> li").array() {
        // Nested lists are extracted first so the parent's own text can be
        // parsed without them.
        let nestedLists = item.children().array().filter { isListTag($0.tagName()) }

        let own = item.copy() as! Element
        for nested in own.children().array() where isListTag(nested.tagName()) {
            try nested.remove()
        }
        let ownInlines = try trimInlineEdges(parseBlockishInlines(own))
        if !ownInlines.isEmpty {
            items.append(ownInlines)
        }

        for nested in nestedLists {
            for nestedItem in try parseListItems(nested) {
                items.append([.text("— ")] + nestedItem)
            }
        }
    }

    return items
}

/// Parses `<dl>` into "term — definition" rows. Each `<dt>` starts a new row;
/// the `<dd>`s that follow are appended to it.
func parseDescriptionList(_ element: Element) throws -> [[ReaderInline]] {
    var items = [[ReaderInline]]()
    var current: [ReaderInline]?

    for child in element.getChildNodes() {
        guard let child = child as? Element else { continue }
        switch child.tagName().lowercased() {
        case "dt":
            if let current, !current.isEmpty { items.append(current) }
            let term = try trimInlineEdges(parseBlockishInlines(child))
            current = term.isEmpty ? nil : [.strong(inlineText(term))]
        case "dd":
            let definition = try trimInlineEdges(parseBlockishInlines(child))
            guard !definition.isEmpty else { continue }
            if current == nil {
                current = definition
            } else {
                current?.append(.text(" — "))
                current?.append(contentsOf: definition)
            }
        default:
            continue
        }
    }

    if let current, !current.isEmpty { items.append(current) }
    return items
}

/// Parses an element whose children may mix inline content with block-level
/// children (`<li>`, `<dd>`, `<blockquote>`, table cells). Block children are
/// joined with a space so their text doesn't fuse together.
func parseBlockishInlines(_ element: Element) throws -> [ReaderInline] {
    let blockTags: Set<String> = ["p", "div", "section", "blockquote"]
    let hasBlockChildren = element.children().array().contains { blockTags.contains($0.tagName().lowercased()) }
    guard hasBlockChildren else {
        return try parseInlinesRaw(element)
    }

    var inlines = [ReaderInline]()
    for node in element.getChildNodes() {
        if let textNode = node as? TextNode {
            let text = cleanInlineText(textNode.text())
            if !text.isEmpty { inlines.append(.text(text)) }
            continue
        }
        guard let child = node as? Element else { continue }
        let parsed = try parseInlinesRaw(child)
        guard !parsed.isEmpty else { continue }
        if !inlines.isEmpty { inlines.append(.text(" ")) }
        inlines.append(contentsOf: parsed)
    }
    return mergeTextInlines(inlines)
}

// MARK: - Tables

/// Converts a `<table>` into the GFM pipe-table string that
/// `ReaderDocumentHTMLBuilder.renderMarkdownTable` already knows how to render
/// as a real `<table>`.
///
/// Without this, `<table>` fell through to `parseBlock`'s `default` case,
/// which recursed into `<tr>`/`<td>` and emitted **one paragraph per cell** —
/// any article containing a comparison table became an unreadable column of
/// orphaned fragments.
func markdownTable(from element: Element) throws -> String? {
    let rowElements = try element.select("tr").array()
    guard !rowElements.isEmpty else { return nil }

    var rows = [[String]]()
    for rowElement in rowElements {
        let cells = rowElement.children().array().filter {
            let tag = $0.tagName().lowercased()
            return tag == "th" || tag == "td"
        }
        guard !cells.isEmpty else { continue }
        rows.append(cells.map { cell in
            // Pipes would break the row encoding, and newlines would split a
            // single cell across rows.
            cleanText((try? cell.text()) ?? "")
                .replacingOccurrences(of: "|", with: "\\|")
        })
    }

    guard !rows.isEmpty else { return nil }
    guard rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }

    // Layout tables (a single row, or a single column) read better as prose
    // than as a one-cell grid, so leave them to the default block handling.
    let columnCount = rows.map(\.count).max() ?? 0
    guard columnCount >= 2, rows.count >= 2 else { return nil }

    func line(_ cells: [String]) -> String {
        var padded = cells
        while padded.count < columnCount { padded.append("") }
        return "| " + padded.joined(separator: " | ") + " |"
    }

    let header = rows.removeFirst()
    var markdown = line(header)
    markdown += "\n| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
    for row in rows {
        markdown += "\n" + line(row)
    }
    return markdown
}

// MARK: - Code

/// Text content of a `<pre>` with line breaks and indentation intact, and the
/// common leading indentation stripped so the reader isn't scrolled sideways
/// by the source document's nesting.
func preformattedText(_ element: Element) -> String {
    let raw = (try? element.text(trimAndNormaliseWhitespace: false)) ?? ""
    let unescaped = (try? Entities.unescape(raw)) ?? raw
    let normalized = unescaped
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{200B}", with: "")
        .replacingOccurrences(of: "\u{FEFF}", with: "")

    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeFirst()
    }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
    }
    guard !lines.isEmpty else { return "" }

    let indents = lines
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
    let commonIndent = indents.min() ?? 0
    if commonIndent > 0 {
        lines = lines.map { String($0.dropFirst(min(commonIndent, $0.count))) }
    }

    return lines
        .joined(separator: "\n")
        .replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
}

/// Extracts a bare language name from a highlighter's class list, e.g.
/// `"language-swift hljs"` → `"swift"`. Passing the raw class through
/// produced `class="language-language-swift hljs"` in the rendered HTML.
func codeLanguage(from element: Element) -> String? {
    let classes = ((try? element.select("code").first()?.className()) ?? "")
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    for name in classes {
        for prefix in ["language-", "lang-", "highlight-"] where name.hasPrefix(prefix) {
            return nonEmpty(String(name.dropFirst(prefix.count)))
        }
    }
    // A single non-decorative class is very likely the language itself.
    let decorative: Set<String> = ["hljs", "highlight", "code", "prettyprint", "sourcecode"]
    let candidates = classes.filter { !decorative.contains($0.lowercased()) }
    return candidates.count == 1 ? nonEmpty(candidates[0]) : nil
}

func parseFallbackDescendants(_ body: Element) throws -> ParsedBlocks {
    var blocks = [ReaderBlock]()
    var media = [MediaDescriptor]()
    var embeds = [EmbedDescriptor]()

    let candidates = try body
        .select("h1,h2,h3,h4,h5,h6,p,blockquote,pre,ul,ol,dl,table,img,video,iframe,figure")
        .array()
        // A nested list/table is already emitted as part of its ancestor, and
        // media inside a <figure> is emitted with the figure's caption. Taking
        // them again here would duplicate the content.
        .filter { element in
            !element.hasAncestor(matching: ["li", "figure", "table", "pre", "blockquote"])
        }
    for element in candidates {
        let parsed = try parseBlock(element)
        blocks.append(contentsOf: parsed.blocks)
        media.append(contentsOf: parsed.media)
        embeds.append(contentsOf: parsed.embeds)
    }

    return ParsedBlocks(
        blocks: dedupeBlocks(blocks),
        media: dedupeMedia(media),
        embeds: dedupeEmbeds(embeds)
    )
}

extension Element {
    /// True when any ancestor of this element has one of `tagNames`.
    func hasAncestor(matching tagNames: [String]) -> Bool {
        var node = parent()
        while let current = node {
            if tagNames.contains(current.tagName().lowercased()) {
                return true
            }
            node = current.parent()
        }
        return false
    }
}

func splitLongParagraph(_ text: String) -> [String] {
    let cleaned = cleanText(text)
    guard cleaned.count > 420 else { return [cleaned] }

    let pieces = cleaned
        .replacingOccurrences(of: "(?<=[.!?])\\s+(?=[A-Z0-9])", with: "\n", options: .regularExpression)
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    return pieces.isEmpty ? [cleaned] : pieces
}
