import Foundation
import NaturalLanguage

public struct SpeechBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading
        case paragraph
        case list
        case blockquote
        case callout
        case other
    }

    /// Matches the `ReaderDocument` block index — used for scroll and
    /// highlight routing. Multiple `SpeechBlock`s can share the same
    /// `index` when a single document block is broken down into sentences
    /// for finer-grained Listen skipping: each sentence becomes its own
    /// `SpeechBlock` but they all point at the same visible paragraph in
    /// the reader HTML for highlight purposes.
    public let index: Int

    /// Monotonic identifier for this speech unit within a playback
    /// session. Used by the Listen feature's skip forward/backward
    /// controls to advance one utterance at a time without conflating
    /// sentences that share a `index`. Equal to `index` by default so
    /// existing block-level callers don't have to change.
    public let sequence: Int

    public let kind: Kind
    public let text: String

    public init(index: Int, kind: Kind, text: String, sequence: Int? = nil) {
        self.index = index
        self.sequence = sequence ?? index
        self.kind = kind
        self.text = text
    }
}

enum ReaderSpeechTextBuilder {
    static func speechBlocks(document: ReaderDocument) -> [SpeechBlock] {
        // swiftlint:disable:next prefer_let_over_var
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

            case let .callout(title, inlines):
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

    /// Fallback path for items whose `ReaderDocument` either doesn't
    /// exist or contains no speakable blocks (e.g. PDFs rendered as
    /// inline page images — their documents are made entirely of
    /// `.figure` blocks, which this builder intentionally excludes). We
    /// paragraph-split the raw text so TTS can advance through the
    /// document one chunk at a time instead of playing a single
    /// megablock. The PDF ingestion pipeline joins per-page text with
    /// `\n\n`, so for PDF items each paragraph-chunk is naturally one
    /// page of extracted text.
    static func speechBlocks(markdown: String) -> [SpeechBlock] {
        let paragraphs = markdown
            .components(separatedBy: "\n\n")
            .map { stripMarkdown($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.isEmpty {
            let collapsed = stripMarkdown(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !collapsed.isEmpty else { return [] }
            return [SpeechBlock(index: 0, kind: .other, text: collapsed)]
        }

        return paragraphs.enumerated().map { idx, text in
            SpeechBlock(index: idx, kind: .paragraph, text: text)
        }
    }

    static func speechBlocks(item: SavedItem?, document: ReaderDocument?) -> [SpeechBlock] {
        if let document {
            let blocks = speechBlocks(document: document)
            if !blocks.isEmpty {
                return blocks
            }
            // Document exists but has no speakable text (e.g. a PDF
            // rendered entirely as `.figure` blocks). Fall through to
            // the plain-text path so Listen still works.
        }
        if let markdown = item?.content, !markdown.isEmpty {
            return speechBlocks(markdown: markdown)
        }
        return []
    }

    /// Breaks each input `SpeechBlock`'s text into individual sentences
    /// using `NLTokenizer` (language-aware) and returns a denser list
    /// where each sentence is its own `SpeechBlock`. Every sentence
    /// inherits its parent's `index` and `kind` (so highlighting and
    /// list-marker logic still works), but receives a fresh monotonic
    /// `sequence` so Listen's skip controls can iterate one sentence at
    /// a time.
    ///
    /// Used by the Listen panel to get sentence-granular playback; the
    /// chunker and other consumers of `speechBlocks(document:)` keep
    /// getting block-level output, so summarization, retrieval, and
    /// position saving are unaffected.
    static func sentenceSplit(_ blocks: [SpeechBlock]) -> [SpeechBlock] {
        // swiftlint:disable:next prefer_let_over_var
        var output: [SpeechBlock] = []
        output.reserveCapacity(blocks.count * 3)
        var sequence = 0

        for block in blocks {
            let sentences = splitIntoSentences(block.text)
            if sentences.isEmpty {
                // Fall through to the parent block verbatim — happens
                // for short / punctuation-less inputs where NLTokenizer
                // returns zero segments.
                output.append(
                    SpeechBlock(
                        index: block.index,
                        kind: block.kind,
                        text: block.text,
                        sequence: sequence
                    )
                )
                sequence += 1
                continue
            }
            for sentence in sentences {
                output.append(
                    SpeechBlock(
                        index: block.index,
                        kind: block.kind,
                        text: sentence,
                        sequence: sequence
                    )
                )
                sequence += 1
            }
        }
        return output
    }

    /// Splits `text` into sentence strings via `NLTokenizer(unit: .sentence)`.
    /// Returns each sentence trimmed of leading/trailing whitespace.
    /// Empty/whitespace-only sentences are dropped.
    private static func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        // swiftlint:disable:next prefer_let_over_var
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences
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
            .split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
        return components.joined(separator: " ")
    }
}
