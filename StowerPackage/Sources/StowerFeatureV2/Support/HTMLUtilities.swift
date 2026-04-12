import Foundation
import SwiftSoup

func extractTitle(document: Document, sourceURL: URL) throws -> String {
    let candidates: [String?] = [
        nonEmpty(try? document.select("meta[property=og:title]").first()?.attr("content")),
        nonEmpty(try? document.select("meta[name=twitter:title]").first()?.attr("content")),
        nonEmpty(try? document.title()),
        sourceURL.host,
        sourceURL.absoluteString,
    ]
    for candidate in candidates {
        if let candidate { return candidate }
    }
    return sourceURL.absoluteString
}

func plainTextFromBlocks(_ blocks: [ReaderBlock]) -> String {
    var parts: [String] = []
    for block in blocks {
        switch block {
        case .paragraph(let inlines): parts.append(inlineText(inlines))
        case .heading(_, let inlines): parts.append(inlineText(inlines))
        case .list(_, let items): parts.append(items.map(inlineText).joined(separator: "\n"))
        case .blockquote(let inlines): parts.append(inlineText(inlines))
        case .code(_, let code): parts.append(code)
        case .figure(let media): if let caption = media.caption { parts.append(caption) }
        case .video(let media): if let caption = media.caption { parts.append(caption) }
        case .embed: continue
        case .table(let markdown): parts.append(markdown)
        case .horizontalRule: continue
        case .callout(let title, let inlines):
            if let title { parts.append(title) }
            parts.append(inlineText(inlines))
        }
    }

    return parts
        .joined(separator: "\n\n")
        .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func inlineText(_ inlines: [ReaderInline]) -> String {
    inlines.map {
        switch $0 {
        case .text(let value): return value
        case .link(let label, _): return label
        case .emphasis(let value): return value
        case .strong(let value): return value
        case .code(let value): return value
        case .strikethrough(let value): return value
        }
    }
    .joined(separator: " ")
    .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func confidenceScore(blockCount: Int, textLength: Int) -> Double {
    let lengthScore = min(Double(textLength) / 2500.0, 1.0)
    let blockScore = min(Double(blockCount) / 30.0, 1.0)
    return (lengthScore * 0.6) + (blockScore * 0.4)
}

func estimateReadingTime(text: String) -> Int {
    let words = text.split(separator: " ").count
    return max(1, Int(ceil(Double(words) / 225.0)))
}

func parseDate(_ raw: String) -> Date? {
    let iso = ISO8601DateFormatter()
    if let value = iso.date(from: raw) { return value }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: raw)
}

func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = cleanText(value)
    return cleaned.isEmpty ? nil : cleaned
}

func cleanText(_ text: String) -> String {
    let unescaped = (try? Entities.unescape(text)) ?? text
    return unescaped
        .replacingOccurrences(of: "[\\t\\n\\r ]+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        .replacingOccurrences(of: "\u{00B6}", with: "")    // pilcrow ¶
        .replacingOccurrences(of: "\u{204B}", with: "")    // reversed pilcrow ⁋
        .replacingOccurrences(of: "\u{2761}", with: "")    // curved stem paragraph ornament ❡
        .replacingOccurrences(of: "\u{200B}", with: "")    // zero-width space
        .replacingOccurrences(of: "\u{FEFF}", with: "")    // zero-width no-break space
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Like `cleanText`, but preserves a single leading/trailing space when the
/// original text had boundary whitespace. Used for TextNode siblings of inline
/// formatting elements (`<a>`, `<strong>`, etc.) so that the space separating
/// e.g. `"word "` from a following `<a>link</a>` survives parsing.
///
/// - Collapses any run of `\t\n\r ` or non-breaking spaces to a single space.
/// - Does NOT trim: if the decoded input starts/ends with whitespace, the
///   result starts/ends with a single `" "`.
/// - Returns `" "` when the input is entirely whitespace, so a pure-whitespace
///   text node between two elements still contributes a space boundary.
/// - Returns `""` only when the input (after stripping removable characters
///   like pilcrows / zero-width spaces) is empty.
func cleanInlineText(_ text: String) -> String {
    let unescaped = (try? Entities.unescape(text)) ?? text
    let normalized = unescaped
        .replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        .replacingOccurrences(of: "\u{00B6}", with: "")    // pilcrow ¶
        .replacingOccurrences(of: "\u{204B}", with: "")    // reversed pilcrow ⁋
        .replacingOccurrences(of: "\u{2761}", with: "")    // curved stem paragraph ornament ❡
        .replacingOccurrences(of: "\u{200B}", with: "")    // zero-width space
        .replacingOccurrences(of: "\u{FEFF}", with: "")    // zero-width no-break space
        .replacingOccurrences(of: "[\\t\\n\\r ]+", with: " ", options: .regularExpression)

    if normalized.isEmpty { return "" }
    if normalized == " " { return " " }

    // Preserve boundary whitespace explicitly so string trimming elsewhere
    // can't accidentally strip it.
    let hasLeading = normalized.first == " "
    let hasTrailing = normalized.last == " "
    let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return " " }

    return (hasLeading ? " " : "") + trimmed + (hasTrailing ? " " : "")
}
