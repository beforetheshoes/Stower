import Foundation

/// Post-load sanitization applied to `ReaderDocument` blocks after decoding
/// from persisted JSON. This lets us fix rendering issues for previously
/// saved articles without requiring re-ingestion.
///
/// Current cleanups:
/// - Removes pilcrow (¶) and similar paragraph marker characters that static
///   site generators add to heading permalinks.
/// - Removes inline links whose label is just a permalink symbol (¶, #, §)
///   or that point to a fragment (#anchor) with a symbol-only label.
/// - Strips zero-width characters that sneak in from some CMS templates.
public func sanitizeLoadedBlocks(_ blocks: [ReaderBlock]) -> [ReaderBlock] {
    blocks.map(sanitizeBlock)
}

private func sanitizeBlock(_ block: ReaderBlock) -> ReaderBlock {
    switch block {
    case let .paragraph(inlines):
        return .paragraph(sanitizeInlines(inlines))
    case let .heading(level, inlines):
        return .heading(level: level, inlines: sanitizeInlines(inlines))
    case let .list(ordered, items):
        return .list(ordered: ordered, items: items.map(sanitizeInlines))
    case let .blockquote(inlines):
        return .blockquote(sanitizeInlines(inlines))
    case let .callout(title, inlines):
        return .callout(
            title: title.map { stripPilcrows($0).trimmingCharacters(in: .whitespacesAndNewlines) },
            inlines: sanitizeInlines(inlines)
        )
    case .code, .figure, .video, .embed, .table, .horizontalRule:
        return block
    }
}

private func sanitizeInlines(_ inlines: [ReaderInline]) -> [ReaderInline] {
    var output: [ReaderInline] = [] // swiftlint:disable:this prefer_let_over_var
    output.reserveCapacity(inlines.count)

    for inline in inlines {
        switch inline {
        case let .text(value):
            // Preserve boundary whitespace — the parser intentionally emits
            // segments like `"word "` so the downstream renderer doesn't
            // smoosh links/bold runs against their neighbours.
            let cleaned = stripPilcrows(value)
            if !cleaned.isEmpty { output.append(.text(cleaned)) }

        case .lineBreak:
            output.append(.lineBreak)

        case let .link(label, url):
            let cleanedLabel = stripPilcrows(label).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedLabel.isEmpty { continue }
            // Drop fragment-only links with symbol-only or very short labels —
            // these are almost always heading permalinks.
            if url.hasPrefix("#"), isSymbolOnly(cleanedLabel) || cleanedLabel.count <= 2 {
                continue
            }
            output.append(.link(label: cleanedLabel, url: url))

        case let .emphasis(value):
            let cleaned = stripPilcrows(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { output.append(.emphasis(cleaned)) }

        case let .strong(value):
            let cleaned = stripPilcrows(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { output.append(.strong(cleaned)) }

        case let .code(value):
            // Don't strip pilcrows from code — they may be meaningful literals.
            output.append(.code(value))

        case let .strikethrough(value):
            let cleaned = stripPilcrows(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { output.append(.strikethrough(cleaned)) }
        }
    }

    return mergeAdjacentText(output)
}

/// Strip pilcrow / zero-width characters and collapse whitespace runs, but
/// do NOT trim. A single leading/trailing space in the input survives — that
/// boundary whitespace is what separates a `.text(...)` segment from an
/// adjacent inline-formatting segment (link, bold, etc.) in the rendered
/// output. Call sites that need trimmed labels (emphasis/strong/strikethrough
/// text, callout titles, link labels) must trim explicitly.
private func stripPilcrows(_ text: String) -> String {
    var result = text
    let targets: [Character] = [
        "\u{00B6}", // pilcrow ¶
        "\u{204B}", // reversed pilcrow ⁋
        "\u{2761}", // curved stem paragraph ❡
        "\u{200B}", // zero-width space
        "\u{FEFF}", // zero-width no-break space
        "\u{200C}", // zero-width non-joiner
        "\u{200D}", // zero-width joiner
    ]
    for target in targets {
        result = result.replacingOccurrences(of: String(target), with: "")
    }
    // Collapse any runs of whitespace left behind, but preserve at most a
    // single leading/trailing space so boundary whitespace survives.
    return result
        .replacingOccurrences(of: "[\\t\\n\\r ]+", with: " ", options: .regularExpression)
}

private func isSymbolOnly(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
        !scalar.properties.isAlphabetic && !CharacterSet.decimalDigits.contains(scalar)
    }
}

private func mergeAdjacentText(_ inlines: [ReaderInline]) -> [ReaderInline] {
    var merged: [ReaderInline] = [] // swiftlint:disable:this prefer_let_over_var
    merged.reserveCapacity(inlines.count)
    for inline in inlines {
        if case .text(let current) = inline,
           case .text(let previous)? = merged.last {
            merged.removeLast()
            // Boundary spaces are already preserved on each segment, so
            // concatenate directly and collapse any double-space at the seam.
            let joined = (previous + current)
                .replacingOccurrences(of: "  ", with: " ")
            merged.append(.text(joined))
        } else {
            merged.append(inline)
        }
    }
    return merged
}
