import Foundation
import StowerData

/// Support for links that point inside a book: footnotes, endnotes,
/// "see chapter 4", a book's own contents page.
///
/// The block parser keeps text, not element ids, so link targets are tracked
/// through it as sentinels. Before a chapter is parsed, every element some
/// link points at gets a sentinel in front of its text and every internal
/// link gets a placeholder URL. After parsing, the sentinels say which block
/// each target landed in, and the placeholders become `#stower-block-N`
/// fragment links that the reader page scrolls to.
enum EPUBInternalLinks {
    static let placeholderPrefix = "stower-book://anchor/"
    /// Private-use characters, so a sentinel cannot collide with book text.
    private static let sentinelOpen: Character = "\u{E000}"
    private static let sentinelClose: Character = "\u{E001}"

    static func sentinel(_ key: Int) -> String {
        "\(sentinelOpen)\(key)\(sentinelClose)"
    }

    static func placeholderURL(_ key: Int) -> String {
        "\(placeholderPrefix)\(key)"
    }

    static func fragmentURL(blockIndex: Int) -> String {
        "#stower-block-\(blockIndex)"
    }

    /// The lookup key for a link target: a document, or an element in it.
    static func targetName(path: String, fragment: String?) -> String {
        guard let fragment, !fragment.isEmpty else { return path }
        return "\(path)#\(fragment)"
    }

    /// Every `href` in a chapter's markup. Used to learn which element ids
    /// are link targets before any chapter is parsed.
    static func hrefs(in xhtml: String) -> [String] {
        xhtml.matches(of: /href\s*=\s*(?:"([^"]*)"|'([^']*)')/).compactMap { match in
            (match.output.1 ?? match.output.2).map(String.init)
        }
    }

    /// Removes sentinels from a chapter's blocks. Returns the cleaned blocks
    /// and, for each sentinel key, the index of the block it was found in.
    /// A block that held nothing but sentinels is dropped and its keys point
    /// at the block that follows.
    static func extractAnchors(from blocks: [ReaderBlock]) -> (blocks: [ReaderBlock], anchors: [Int: Int]) {
        var cleaned = [ReaderBlock]()
        var anchors = [Int: Int]()
        for block in blocks {
            var keys = [Int]()
            let stripped = strip(block, keys: &keys)
            for key in keys where anchors[key] == nil {
                anchors[key] = cleaned.count
            }
            if let stripped {
                cleaned.append(stripped)
            }
        }
        // A sentinel after the last block still needs somewhere to land.
        let lastIndex = max(cleaned.count - 1, 0)
        return (cleaned, anchors.mapValues { min($0, lastIndex) })
    }

    /// Turns placeholder links into fragment links. A placeholder whose
    /// target was never found becomes plain text.
    static func resolveLinks(in blocks: [ReaderBlock], blockIndexByKey: [Int: Int]) -> [ReaderBlock] {
        blocks.map { block in
            mapInlines(of: block) { inline in
                guard case let .link(label, url) = inline,
                      url.hasPrefix(placeholderPrefix)
                else { return inline }
                guard let key = Int(url.dropFirst(placeholderPrefix.count)),
                      let blockIndex = blockIndexByKey[key]
                else { return .text(label) }
                return .link(label: label, url: fragmentURL(blockIndex: blockIndex))
            }
        }
    }

    // MARK: - Sentinel stripping

    private static func strip(_ block: ReaderBlock, keys: inout [Int]) -> ReaderBlock? {
        switch block {
        case .paragraph(let inlines):
            let cleaned = strip(inlines, keys: &keys)
            return isBlank(cleaned) ? nil : .paragraph(cleaned)
        case let .heading(level, inlines):
            let cleaned = strip(inlines, keys: &keys)
            return isBlank(cleaned) ? nil : .heading(level: level, inlines: cleaned)
        case .blockquote(let inlines):
            let cleaned = strip(inlines, keys: &keys)
            return isBlank(cleaned) ? nil : .blockquote(cleaned)
        case let .list(ordered, items):
            let cleaned = items
                .map { strip($0, keys: &keys) }
                .filter { !isBlank($0) }
            return cleaned.isEmpty ? nil : .list(ordered: ordered, items: cleaned)
        case let .callout(title, inlines):
            let cleanedTitle = title.map { strip($0, keys: &keys) }
            return .callout(title: cleanedTitle, inlines: strip(inlines, keys: &keys))
        case let .code(language, code):
            return .code(language: language, code: strip(code, keys: &keys))
        case .table(let markdown):
            return .table(markdown: strip(markdown, keys: &keys))
        case .figure(var media):
            media.caption = media.caption.map { strip($0, keys: &keys) }
            media.altText = media.altText.map { strip($0, keys: &keys) }
            return .figure(media: media)
        case .video, .embed, .horizontalRule:
            return block
        }
    }

    private static func strip(_ inlines: [ReaderInline], keys: inout [Int]) -> [ReaderInline] {
        inlines.compactMap { inline -> ReaderInline? in
            switch inline {
            case .text(let value):
                let cleaned = strip(value, keys: &keys)
                return cleaned.isEmpty ? nil : .text(cleaned)
            case let .link(label, url):
                return .link(label: strip(label, keys: &keys), url: url)
            case .emphasis(let value):
                return .emphasis(strip(value, keys: &keys))
            case .strong(let value):
                return .strong(strip(value, keys: &keys))
            case .code(let value):
                return .code(strip(value, keys: &keys))
            case .strikethrough(let value):
                return .strikethrough(strip(value, keys: &keys))
            case .lineBreak:
                return inline
            }
        }
    }

    private static func strip(_ text: String, keys: inout [Int]) -> String {
        guard text.contains(sentinelOpen) else { return text }
        var output = ""
        var digits: String?
        for character in text {
            if character == sentinelOpen {
                digits = ""
            } else if character == sentinelClose {
                if let key = digits.flatMap(Int.init) {
                    keys.append(key)
                }
                digits = nil
            } else if digits != nil {
                digits?.append(character)
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func isBlank(_ inlines: [ReaderInline]) -> Bool {
        inlines.allSatisfy { inline in
            switch inline {
            case .text(let value):
                value.allSatisfy(\.isWhitespace)
            case .lineBreak:
                true
            case .link, .emphasis, .strong, .code, .strikethrough:
                false
            }
        }
    }

    private static func mapInlines(
        of block: ReaderBlock,
        _ transform: (ReaderInline) -> ReaderInline
    ) -> ReaderBlock {
        switch block {
        case .paragraph(let inlines):
            .paragraph(inlines.map(transform))
        case let .heading(level, inlines):
            .heading(level: level, inlines: inlines.map(transform))
        case .blockquote(let inlines):
            .blockquote(inlines.map(transform))
        case let .list(ordered, items):
            .list(ordered: ordered, items: items.map { $0.map(transform) })
        case let .callout(title, inlines):
            .callout(title: title, inlines: inlines.map(transform))
        case .code, .table, .figure, .video, .embed, .horizontalRule:
            block
        }
    }
}
