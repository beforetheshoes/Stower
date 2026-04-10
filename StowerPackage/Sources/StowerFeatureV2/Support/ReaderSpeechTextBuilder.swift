import Foundation

public struct SpeechBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading
        case paragraph
        case list
        case blockquote
        case callout
        case other
    }

    // Matches the ReaderDocument block index (used for scroll + highlight routing).
    public let index: Int
    public let kind: Kind
    public let text: String
}

enum ReaderSpeechTextBuilder {
    static func speechBlocks(document: ReaderDocument) -> [SpeechBlock] {
        var output: [SpeechBlock] = []
        output.reserveCapacity(document.blocks.count)

        for (index, block) in document.blocks.enumerated() {
            switch block {
            case .paragraph(let inlines):
                let text = ReaderTextLayoutSupport.inlinePlainText(from: inlines)
                if !text.isEmpty {
                    output.append(SpeechBlock(index: index, kind: .paragraph, text: text))
                }

            case .heading(_, let inlines):
                let text = ReaderTextLayoutSupport.inlinePlainText(from: inlines)
                if !text.isEmpty {
                    output.append(SpeechBlock(index: index, kind: .heading, text: text))
                }

            case .list(_, let items):
                let (text, _) = ReaderTextLayoutSupport.listSpeechTextAndRanges(items: items)
                if !text.isEmpty {
                    output.append(SpeechBlock(index: index, kind: .list, text: text))
                }

            case .blockquote(let inlines):
                let text = ReaderTextLayoutSupport.inlinePlainText(from: inlines)
                if !text.isEmpty {
                    output.append(SpeechBlock(index: index, kind: .blockquote, text: text))
                }

            case .callout(let title, let inlines):
                let body = ReaderTextLayoutSupport.inlinePlainText(from: inlines)
                let combined: String
                if let title, !title.isEmpty, !body.isEmpty {
                    combined = "\(title). \(body)"
                } else if let title, !title.isEmpty {
                    combined = title
                } else {
                    combined = body
                }
                if !combined.isEmpty {
                    output.append(SpeechBlock(index: index, kind: .callout, text: combined))
                }

            case .code, .figure, .video, .embed, .table, .horizontalRule:
                // Intentionally excluded in MVP.
                continue
            }
        }

        return output
    }

    static func speechBlocks(markdown: String) -> [SpeechBlock] {
        let text = stripMarkdown(markdown)
        guard !text.isEmpty else { return [] }
        return [SpeechBlock(index: 0, kind: .other, text: text)]
    }

    static func speechBlocks(item: SavedItem?, document: ReaderDocument?) -> [SpeechBlock] {
        if let document {
            return speechBlocks(document: document)
        }
        if let markdown = item?.content, !markdown.isEmpty {
            return speechBlocks(markdown: markdown)
        }
        return []
    }

    private static func stripMarkdown(_ markdown: String) -> String {
        // Cheap, safe fallback. This doesn't aim to be a full Markdown parser.
        var text = markdown
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "#", with: "")
        text = text.replacingOccurrences(of: "*", with: "")
        text = text.replacingOccurrences(of: "_", with: "")
        text = text.replacingOccurrences(of: "[", with: "")
        text = text.replacingOccurrences(of: "]", with: "")
        text = text.replacingOccurrences(of: "(", with: "")
        text = text.replacingOccurrences(of: ")", with: "")

        // Collapse whitespace.
        let components = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        return components.joined(separator: " ")
    }
}
