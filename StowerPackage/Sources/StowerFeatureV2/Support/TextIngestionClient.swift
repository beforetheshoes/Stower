import Dependencies
import Foundation
import Markdown
import StowerData

public struct TextIngestionClient: Sendable {
    public var ingest: @Sendable (_ text: String, _ titleHint: String?, _ mode: TextImportMode) async throws -> IngestionResult

    public init(
        ingest: @escaping @Sendable (_ text: String, _ titleHint: String?, _ mode: TextImportMode) async throws -> IngestionResult
    ) {
        self.ingest = ingest
    }

    public static let live = TextIngestionClient { text, titleHint, mode in
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMode = TextImportDetector.inferredMode(for: trimmed, preferred: mode)
        switch resolvedMode {
        case .plainText:
            return IngestionResult.sharedText(trimmed, title: titleHint)
        case .markdown:
            return (try? await MarkdownIngestionClient.live.ingest(trimmed, titleHint)) ?? IngestionResult.sharedText(trimmed, title: titleHint)
        case .auto:
            return IngestionResult.sharedText(trimmed, title: titleHint)
        }
    }
}

public struct MarkdownIngestionClient: Sendable {
    public var ingest: @Sendable (_ markdown: String, _ titleHint: String?) async throws -> IngestionResult

    public init(
        ingest: @escaping @Sendable (_ markdown: String, _ titleHint: String?) async throws -> IngestionResult
    ) {
        self.ingest = ingest
    }

    public static let live = MarkdownIngestionClient { markdown, titleHint in
        let blocks = MarkdownBlockParser.parse(markdown)
        let title = resolvedTextImportTitle(
            documentTitle: MarkdownBlockParser.firstHeadingTitle(in: blocks),
            titleHint: titleHint
        )
        let plainText = markdownPlainText(from: blocks)
        guard !blocks.isEmpty else {
            return IngestionResult.sharedText(markdown, title: titleHint)
        }
        return IngestionResult.structuredText(
            title: title,
            blocks: blocks,
            plainText: plainText
        )
    }
}

private func markdownPlainText(from blocks: [ReaderBlock]) -> String {
    let parts = blocks.compactMap { block -> String? in
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines), .blockquote(let inlines):
            return ReaderTextLayoutSupport.inlinePlainText(from: inlines)
        case .list(_, let items):
            return items.map { ReaderTextLayoutSupport.inlinePlainText(from: $0) }.joined(separator: "\n")
        case .code(_, let code):
            return code
        case .table(let markdown):
            return markdown
        case let .callout(title, inlines):
            let calloutBody = ReaderTextLayoutSupport.inlinePlainText(from: inlines)
            if let title, !title.isEmpty {
                return [title, calloutBody].joined(separator: "\n")
            }
            return calloutBody
        case .figure(let media), .video(let media):
            return media.caption?.isEmpty == false ? media.caption : nil
        case .embed, .horizontalRule:
            return nil
        }
    }

    return parts
        .joined(separator: "\n\n")
        .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private enum TextIngestionClientKey: DependencyKey {
    static let liveValue = TextIngestionClient.live
    static let testValue = TextIngestionClient.live
}

extension DependencyValues {
    public var textIngestionClient: TextIngestionClient {
        get { self[TextIngestionClientKey.self] }
        set { self[TextIngestionClientKey.self] = newValue }
    }
}

private enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [ReaderBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks = [ReaderBlock]()
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let block = parseHeading(line) {
                blocks.append(block)
                index += 1
                continue
            }

            if let parsed = parseFencedCode(lines, index: index) {
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if let parsed = parseTable(lines, index: index) {
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if isHorizontalRule(line) {
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            if let parsed = parseBlockquote(lines, index: index) {
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if let parsed = parseList(lines, index: index) {
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            let parsed = parseParagraph(lines, index: index)
            blocks.append(parsed.block)
            index = parsed.nextIndex
        }

        return blocks
    }

    static func firstHeadingTitle(in blocks: [ReaderBlock]) -> String? {
        for block in blocks {
            if case .heading(level: 1, inlines: let inlines) = block {
                let text = inlineText(inlines).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func parseHeading(_ line: String) -> ReaderBlock? {
        guard let range = line.range(of: #"^\s{0,3}(#{1,6})\s+(.+?)\s*$"#, options: .regularExpression) else {
            return nil
        }
        let match = String(line[range])
        let hashes = match.prefix { $0 == "#" }
        let content = match.drop { $0 == "#" || $0.isWhitespace }
        return .heading(level: hashes.count, inlines: MarkdownInlineParser.parse(String(content)))
    }

    private static func parseFencedCode(_ lines: [String], index: Int) -> (block: ReaderBlock, nextIndex: Int)? {
        let line = lines[index]
        guard let range = line.range(of: #"^\s{0,3}(```|~~~)(.*)$"#, options: .regularExpression) else {
            return nil
        }
        let opener = String(line[range]).trimmingCharacters(in: .whitespaces)
        let fence = opener.hasPrefix("```") ? "```" : "~~~"
        let language = opener.dropFirst(3).trimmingCharacters(in: .whitespaces)
        var body = [String]()
        var cursor = index + 1
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix(fence) {
                return (
                    .code(language: language.isEmpty ? nil : language, code: body.joined(separator: "\n")),
                    cursor + 1
                )
            }
            body.append(lines[cursor])
            cursor += 1
        }
        return (
            .code(language: language.isEmpty ? nil : language, code: body.joined(separator: "\n")),
            cursor
        )
    }

    private static func parseTable(_ lines: [String], index: Int) -> (block: ReaderBlock, nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard header.contains("|"),
              separator.range(of: #"^\|?[\s:\-|\t]+\|?\s*$"#, options: .regularExpression) != nil,
              separator.contains("-")
        else {
            return nil
        }

        var collected = [String]()
        collected.append(contentsOf: [header, separator])
        var cursor = index + 2
        while cursor < lines.count {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.contains("|") else { break }
            collected.append(line)
            cursor += 1
        }
        return (.table(markdown: collected.joined(separator: "\n")), cursor)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil
    }

    private static func parseBlockquote(_ lines: [String], index: Int) -> (block: ReaderBlock, nextIndex: Int)? {
        guard lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") else {
            return nil
        }
        var parts = [String]()
        var cursor = index
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if !content.isEmpty {
                parts.append(content)
            }
            cursor += 1
        }
        return (.blockquote(MarkdownInlineParser.parse(parts.joined(separator: " "))), cursor)
    }

    private static func parseList(_ lines: [String], index: Int) -> (block: ReaderBlock, nextIndex: Int)? {
        let first = lines[index]
        guard let firstMarker = listMatch(in: first) else { return nil }

        var items = [[String]]()
        items.append([firstMarker.content])
        var cursor = index + 1

        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            if let marker = listMatch(in: line), marker.ordered == firstMarker.ordered {
                items.append([marker.content])
                cursor += 1
                continue
            }

            let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
            if indentation >= 2, !items.isEmpty {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                if !continuation.isEmpty {
                    items[items.count - 1].append(continuation)
                }
                cursor += 1
                continue
            }
            break
        }

        let parsedItems = items.map { MarkdownInlineParser.parse($0.joined(separator: " ")) }
        return (.list(ordered: firstMarker.ordered, items: parsedItems), cursor)
    }

    private static func parseParagraph(_ lines: [String], index: Int) -> (block: ReaderBlock, nextIndex: Int) {
        var parts = [String]()
        var cursor = index
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            if cursor != index {
                if parseHeading(line) != nil || parseFencedCode(lines, index: cursor) != nil ||
                    parseTable(lines, index: cursor) != nil || isHorizontalRule(line) ||
                    parseBlockquote(lines, index: cursor) != nil || parseList(lines, index: cursor) != nil {
                    break
                }
            }
            parts.append(line.trimmingCharacters(in: .whitespaces))
            cursor += 1
        }
        return (.paragraph(MarkdownInlineParser.parse(parts.joined(separator: " "))), cursor)
    }

    private static func listMatch(in line: String) -> (ordered: Bool, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: #"^[-*+]\s+.+$"#, options: .regularExpression) {
            let content = String(trimmed[range]).dropFirst().trimmingCharacters(in: .whitespaces)
            return (false, content)
        }
        if trimmed.range(of: #"^\d+\.\s+.+$"#, options: .regularExpression) != nil,
           let dot = trimmed.firstIndex(of: ".") {
            let content = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            return (true, content)
        }
        return nil
    }
}

private enum MarkdownInlineParser {
    static func parse(_ markdown: String) -> [ReaderInline] {
        let document = Document(parsing: markdown)
        return collectInlines(from: document)
    }

    private static func collectInlines(from markup: any Markup) -> [ReaderInline] {
        if let text = markup as? Text {
            return [.text(text.string)]
        }
        if markup is SoftBreak || markup is LineBreak {
            return [.text(" ")]
        }
        if let inlineCode = markup as? InlineCode {
            return [.code(inlineCode.code)]
        }
        if let emphasis = markup as? Emphasis {
            return [.emphasis(plainText(from: emphasis))]
        }
        if let strong = markup as? Strong {
            return [.strong(plainText(from: strong))]
        }
        if let strikethrough = markup as? Strikethrough {
            return [.strikethrough(plainText(from: strikethrough))]
        }
        if let link = markup as? Link {
            return [.link(label: plainText(from: link), url: link.destination ?? "")]
        }

        var output = [ReaderInline]()
        for child in markup.children {
            output.append(contentsOf: collectInlines(from: child))
        }
        return mergeText(output)
    }

    private static func plainText(from markup: any Markup) -> String {
        if let text = markup as? Text {
            return text.string
        }
        if markup is SoftBreak || markup is LineBreak {
            return " "
        }
        if let inlineCode = markup as? InlineCode {
            return inlineCode.code
        }
        return markup.children.map(plainText(from:)).joined()
    }

    private static func mergeText(_ inlines: [ReaderInline]) -> [ReaderInline] {
        var output = [ReaderInline]()
        for inline in inlines {
            switch inline {
            case .text(let value):
                guard !value.isEmpty else { continue }
                if case .text(let current)? = output.last {
                    output[output.count - 1] = .text(current + value)
                } else {
                    output.append(.text(value))
                }
            default:
                output.append(inline)
            }
        }
        return output
    }
}
