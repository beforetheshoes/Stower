import Foundation
import SwiftUI

/// Builds `AttributedString`s and body-text snippets that highlight the
/// current search query in library row views, so the user can see which
/// matches in each row triggered the filter.
///
/// Two entry points:
///  - `highlighted(_:query:)` — wraps a string (typically the item
///    title) in an `AttributedString` with every case/diacritic-
///    insensitive occurrence of `query` bolded and given a yellow
///    background fill.
///  - `bodySnippet(item:query:)` — when the title already matches the
///    query, returns nil (don't duplicate context). Otherwise finds
///    the first body-text match and returns a ±64-character window
///    around it with the match highlighted, so PDF hits and other
///    body-only matches become visible in the library list.
enum LibrarySearchHighlight {
    private static let snippetRadius = 64
    private static let searchOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive,
    ]

    /// Highlights every occurrence of `query` in `text`. Returns the
    /// plain attributed string unchanged when `query` is empty — the
    /// library row is drawn in its normal style during non-search mode.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var attr = AttributedString(text)
        guard !trimmedQuery.isEmpty else { return attr }
        applyHighlights(to: &attr, plain: text, query: trimmedQuery)
        return attr
    }

    /// Returns a highlighted snippet of `item.content` centered on the
    /// first match of `query`. Returns nil when:
    ///   - the query is empty, or
    ///   - the title already contains the query (the title row does
    ///     the highlighting — a snippet would be redundant), or
    ///   - the body text doesn't actually contain the query
    ///     (probably matched on author/siteName/etc. instead).
    static func bodySnippet(item: SavedItem, query: String) -> AttributedString? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        if item.title.range(of: trimmedQuery, options: searchOptions) != nil {
            return nil
        }

        // Prefer the excerpt if it contains a match — it's already
        // short and hand-picked. Otherwise fall back to the full body.
        let haystacks: [String] = [
            item.excerpt.flatMap { $0.isEmpty ? nil : $0 } ?? "",
            item.content,
        ]
        for haystack in haystacks {
            guard !haystack.isEmpty else { continue }
            if let snippet = makeSnippet(from: haystack, query: trimmedQuery) {
                return snippet
            }
        }
        return nil
    }

    // MARK: - Private

    /// Finds the first `query` match in `text` and returns a ±snippetRadius
    /// window around it as an `AttributedString` with the match
    /// highlighted. Prepends/appends `…` when the snippet was clipped
    /// from the middle of the source text.
    private static func makeSnippet(from text: String, query: String) -> AttributedString? {
        guard let firstMatch = text.range(of: query, options: searchOptions) else {
            return nil
        }

        // Radius is measured in characters (extended grapheme clusters),
        // which is what the user visually perceives.
        let beforeStart = text.index(
            firstMatch.lowerBound,
            offsetBy: -snippetRadius,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let afterEnd = text.index(
            firstMatch.upperBound,
            offsetBy: snippetRadius,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        var snippet = String(text[beforeStart..<afterEnd])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // Collapse runs of whitespace so snippets don't have weird
        // ragged gaps from paragraph breaks in the source.
        while snippet.contains("  ") {
            snippet = snippet.replacingOccurrences(of: "  ", with: " ")
        }

        if beforeStart != text.startIndex {
            snippet = "…" + snippet
        }
        if afterEnd != text.endIndex {
            snippet += "…"
        }

        var attr = AttributedString(snippet)
        applyHighlights(to: &attr, plain: snippet, query: query)
        return attr
    }

    /// Iterates every case/diacritic-insensitive occurrence of `query`
    /// in `plain` and applies a yellow highlight + bold weight to the
    /// corresponding range in `attr`. Uses character-offset arithmetic
    /// to translate between the `String` index space and the
    /// `AttributedString` index space, because the two types do not
    /// share an index type.
    private static func applyHighlights(
        to attr: inout AttributedString,
        plain: String,
        query: String
    ) {
        guard !query.isEmpty else { return }

        var cursor = plain.startIndex
        while cursor < plain.endIndex,
              let range = plain.range(
                of: query,
                options: searchOptions,
                range: cursor..<plain.endIndex
              ) {
            let startOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let endOffset = plain.distance(from: plain.startIndex, to: range.upperBound)

            let attrStart = attr.index(attr.startIndex, offsetByCharacters: startOffset)
            let attrEnd = attr.index(attr.startIndex, offsetByCharacters: endOffset)
            let attrRange = attrStart..<attrEnd

            attr[attrRange].backgroundColor = Color.yellow.opacity(0.35)
            attr[attrRange].inlinePresentationIntent = .stronglyEmphasized

            cursor = range.upperBound
        }
    }
}
