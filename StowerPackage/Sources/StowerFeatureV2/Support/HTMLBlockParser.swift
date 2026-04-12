import Foundation
import SwiftSoup

struct ParsedBlocks {
    var blocks: [ReaderBlock]
    var media: [MediaDescriptor]
    var embeds: [EmbedDescriptor]
}

func parseBlocks(root: Element, baseURL: URL) throws -> ParsedBlocks {
    let cleanedDoc = try SwiftSoup.parseBodyFragment(try root.outerHtml(), baseURL.absoluteString)
    guard let body = cleanedDoc.body() else {
        return ParsedBlocks(blocks: [], media: [], embeds: [])
    }

    try body.select(
        "script, style, svg, canvas, template, nav, footer, header, aside, form, button, [aria-hidden=true], [hidden], .sr-only, .visually-hidden, .screen-reader-text, .sidebar, .related, .share, .comments"
    ).remove()

    // Remove permalink/headerlink anchors commonly added next to headings by
    // static site generators (MkDocs, Sphinx, Hugo, Jekyll, Docusaurus, etc.).
    // These typically render as "¶" or "#" and link back to the heading's anchor.
    try body.select(
        "a.headerlink, a.anchor, a.anchorlink, a.anchor-link, a.anchor_link, a.permalink, a.heading-link, a.heading_link, a.hash-link, a.header-link, .headerlink, .anchorjs-link"
    ).remove()
    try body.select("h1 > a[href^=#], h2 > a[href^=#], h3 > a[href^=#], h4 > a[href^=#], h5 > a[href^=#], h6 > a[href^=#]")
        .remove()

    var blocks: [ReaderBlock] = []
    var media: [MediaDescriptor] = []
    var embeds: [EmbedDescriptor] = []

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
        let inlines = try parseInlines(element)
        var blocks: [ReaderBlock] = inlines.isEmpty ? [] : [.paragraph(inlines)]
        var media: [MediaDescriptor] = []
        var embeds: [EmbedDescriptor] = []

        let mediaNodes = try element.select("img,picture,video,iframe,figure").array()
        for mediaNode in mediaNodes {
            let parsed = try parseBlock(mediaNode)
            blocks.append(contentsOf: parsed.blocks)
            media.append(contentsOf: parsed.media)
            embeds.append(contentsOf: parsed.embeds)
        }

        return ParsedBlocks(blocks: dedupeBlocks(blocks), media: dedupeMedia(media), embeds: dedupeEmbeds(embeds))

    case "ul", "ol":
        let listItems = try element.select("> li").array().map { try parseInlines($0) }.filter { !$0.isEmpty }
        return ParsedBlocks(blocks: listItems.isEmpty ? [] : [.list(ordered: tag == "ol", items: listItems)], media: [], embeds: [])

    case "blockquote":
        let inlines = try parseInlines(element)
        return ParsedBlocks(blocks: inlines.isEmpty ? [] : [.blockquote(inlines)], media: [], embeds: [])

    case "pre":
        let language = nonEmpty(try? element.select("code").first()?.attr("class"))
        let code = cleanText((try? element.text()) ?? "")
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
    var inlines: [ReaderInline] = []

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
            inlines.append(.text("\n"))

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
    var merged: [ReaderInline] = []
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
        let trimmed = String(first.drop(while: { $0 == " " }))
        if trimmed.isEmpty {
            result.removeFirst()
        } else {
            result[0] = .text(trimmed)
        }
    }
    if case .text(let last)? = result.last {
        let trimmed = String(last.reversed().drop(while: { $0 == " " }).reversed())
        if trimmed.isEmpty {
            result.removeLast()
        } else {
            result[result.count - 1] = .text(trimmed)
        }
    }
    return result
}

func parseFallbackDescendants(_ body: Element) throws -> ParsedBlocks {
    var blocks: [ReaderBlock] = []
    var media: [MediaDescriptor] = []
    var embeds: [EmbedDescriptor] = []

    let candidates = try body.select("h1,h2,h3,h4,h5,h6,p,blockquote,pre,ul,ol,img,video,iframe,figure").array()
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
