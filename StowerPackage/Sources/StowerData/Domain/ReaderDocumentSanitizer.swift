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
    case .paragraph(let inlines):
        return .paragraph(sanitizeInlines(inlines))
    case .heading(let level, let inlines):
        return .heading(level: level, inlines: sanitizeInlines(inlines))
    case .list(let ordered, let items):
        return .list(ordered: ordered, items: items.map(sanitizeInlines))
    case .blockquote(let inlines):
        return .blockquote(sanitizeInlines(inlines))
    case .callout(let title, let inlines):
        return .callout(title: title.map(stripPilcrows), inlines: sanitizeInlines(inlines))
    case .code, .figure, .video, .embed, .table, .horizontalRule:
        return block
    }
}

private func sanitizeInlines(_ inlines: [ReaderInline]) -> [ReaderInline] {
    var output: [ReaderInline] = []
    output.reserveCapacity(inlines.count)

    for inline in inlines {
        switch inline {
        case .text(let value):
            let cleaned = stripPilcrows(value)
            if !cleaned.isEmpty { output.append(.text(cleaned)) }

        case .link(let label, let url):
            let cleanedLabel = stripPilcrows(label).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedLabel.isEmpty { continue }
            // Drop fragment-only links with symbol-only or very short labels —
            // these are almost always heading permalinks.
            if url.hasPrefix("#"), isSymbolOnly(cleanedLabel) || cleanedLabel.count <= 2 {
                continue
            }
            output.append(.link(label: cleanedLabel, url: url))

        case .emphasis(let value):
            let cleaned = stripPilcrows(value)
            if !cleaned.isEmpty { output.append(.emphasis(cleaned)) }

        case .strong(let value):
            let cleaned = stripPilcrows(value)
            if !cleaned.isEmpty { output.append(.strong(cleaned)) }

        case .code(let value):
            // Don't strip pilcrows from code — they may be meaningful literals.
            output.append(.code(value))

        case .strikethrough(let value):
            let cleaned = stripPilcrows(value)
            if !cleaned.isEmpty { output.append(.strikethrough(cleaned)) }
        }
    }

    return mergeAdjacentText(output)
}

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
    // Collapse any runs of whitespace left behind.
    return result
        .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isSymbolOnly(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
        !scalar.properties.isAlphabetic && !CharacterSet.decimalDigits.contains(scalar)
    }
}

private func mergeAdjacentText(_ inlines: [ReaderInline]) -> [ReaderInline] {
    var merged: [ReaderInline] = []
    merged.reserveCapacity(inlines.count)
    for inline in inlines {
        if case .text(let current) = inline,
           case .text(let previous)? = merged.last {
            merged.removeLast()
            merged.append(.text(previous + " " + current))
        } else {
            merged.append(inline)
        }
    }
    return merged
}
