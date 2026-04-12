// swiftlint:disable no_sensitive_logging
import Foundation
import NaturalLanguage
import StowerData

// Splits an article into chunks sized for the on-device Foundation Model's
// context window. Prefers splitting on block boundaries (paragraphs, headings,
// lists) to keep each chunk semantically coherent. Falls back to sentence-
// level splitting when a single block exceeds the budget.
//
// Token counts are approximated at 4 characters per token for English, per
// Apple's TN3193. Callers that need precision can supply their own
// `tokenCounter` (e.g. wired to `SystemLanguageModel.tokenCount(for:)` for
// instructions), but the approximation is accurate enough for budgeting
// decisions in practice.
public enum ArticleChunker {
    public struct Chunk: Equatable, Sendable {
        public let index: Int
        public let text: String
        public let approxTokens: Int

        public init(index: Int, text: String, approxTokens: Int) {
            self.index = index
            self.text = text
            self.approxTokens = approxTokens
        }
    }

    /// Splits the article into chunks that each fit within `budgetTokens`.
    /// - Parameters:
    ///   - document: The structured `ReaderDocument` if available. Preferred
    ///     because block boundaries give better chunk coherence.
    ///   - plainText: Fallback raw text used when `document` is nil.
    ///   - budgetTokens: Target maximum tokens per chunk.
    ///   - tokenCounter: Token estimator. Defaults to `chars / 4` per Apple's
    ///     English-language guidance.
    public static func chunks(
        from document: ReaderDocument?,
        plainText: String,
        budgetTokens: Int,
        tokenCounter: @Sendable (String) -> Int = Self.approxTokenCount
    ) -> [Chunk] {
        let rawBlocks = blockTexts(document: document, plainText: plainText)
        guard !rawBlocks.isEmpty else {
            if plainText.isEmpty {
                return []
            }
            return [Chunk(index: 0, text: plainText, approxTokens: tokenCounter(plainText))]
        }

        // swiftlint:disable:next prefer_let_over_var
        var chunks: [Chunk] = []
        // swiftlint:disable:next prefer_let_over_var
        var currentBlocks: [String] = []
        var currentTokens = 0
        var chunkIndex = 0

        func flushCurrent() {
            guard !currentBlocks.isEmpty else { return }
            let text = currentBlocks.joined(separator: "\n\n")
            chunks.append(Chunk(index: chunkIndex, text: text, approxTokens: currentTokens))
            chunkIndex += 1
            currentBlocks.removeAll(keepingCapacity: true)
            currentTokens = 0
        }

        for block in rawBlocks {
            let blockTokens = tokenCounter(block)

            // Block alone exceeds the budget: flush pending, then sentence-split.
            if blockTokens > budgetTokens {
                flushCurrent()
                for sentenceChunk in sentenceChunks(text: block, budgetTokens: budgetTokens, tokenCounter: tokenCounter) {
                    chunks.append(Chunk(index: chunkIndex, text: sentenceChunk.text, approxTokens: sentenceChunk.approxTokens))
                    chunkIndex += 1
                }
                continue
            }

            // Block fits by itself; check if adding it overflows the in-progress chunk.
            if currentTokens + blockTokens > budgetTokens && !currentBlocks.isEmpty {
                flushCurrent()
            }

            currentBlocks.append(block)
            currentTokens += blockTokens
        }

        flushCurrent()
        return chunks
    }

    // Rough token estimator. Apple's TN3193 gives 3-4 characters per token
    // for English; we deliberately pick the conservative end (3) because
    // real articles routinely tokenize worse than the optimistic end
    // (punctuation, URLs, inline code, numbers, emoji). Underestimating
    // tokens pushes borderline articles out of the single-session fast path
    // and into chunking, which is always recoverable -- overestimating and
    // then throwing `exceededContextWindowSize` mid-generation is not.
    public static func approxTokenCount(_ text: String) -> Int {
        (text.count + 2) / 3
    }

    // MARK: - Private

    /// Extracts per-block plain-text strings from the document (preferred) or
    /// paragraph-splits `plainText` as a fallback. Reuses the same block
    /// walking logic as `ReaderSpeechTextBuilder` so the chunker stays in sync
    /// with the set of blocks TTS considers "readable."
    ///
    /// For PDF items rendered as page images, the document's blocks are
    /// all `.figure`s (which `ReaderSpeechTextBuilder` intentionally
    /// excludes), so the block walk returns an empty list. We fall through
    /// to paragraph-splitting `plainText` in that case — the PDF
    /// ingestion pipeline joins per-page text with `\n\n`, so the fallback
    /// naturally produces one chunk candidate per page.
    private static func blockTexts(document: ReaderDocument?, plainText: String) -> [String] {
        if let document {
            let blocks = ReaderSpeechTextBuilder.speechBlocks(document: document).map { $0.text }
            if !blocks.isEmpty {
                return blocks
            }
        }
        let paragraphs = plainText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs
    }

    /// Breaks an oversized block into sentence-bounded chunks. Uses
    /// `NLTokenizer` for language-aware sentence detection; falls back to
    /// returning the whole text as a single chunk if segmentation produces
    /// nothing.
    private static func sentenceChunks(
        text: String,
        budgetTokens: Int,
        tokenCounter: @Sendable (String) -> Int
    ) -> [Chunk] {
        let sentences = splitIntoSentences(text)
        if sentences.isEmpty {
            // Last-resort: emit the raw text as one chunk even though it
            // exceeds the budget. The model call will likely fail, but the
            // alternative is silently dropping content.
            return [Chunk(index: 0, text: text, approxTokens: tokenCounter(text))]
        }

        // swiftlint:disable:next prefer_let_over_var
        var chunks: [Chunk] = []
        // swiftlint:disable:next prefer_let_over_var
        var current: [String] = []
        var currentTokens = 0

        for sentence in sentences {
            let sentenceTokens = tokenCounter(sentence)
            if currentTokens + sentenceTokens > budgetTokens && !current.isEmpty {
                let joined = current.joined(separator: " ")
                chunks.append(Chunk(index: 0, text: joined, approxTokens: currentTokens))
                current = [sentence]
                currentTokens = sentenceTokens
            } else {
                current.append(sentence)
                currentTokens += sentenceTokens
            }
        }

        if !current.isEmpty {
            let joined = current.joined(separator: " ")
            chunks.append(Chunk(index: 0, text: joined, approxTokens: currentTokens))
        }

        return chunks
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        // swiftlint:disable:next prefer_let_over_var
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }
}
// swiftlint:enable no_sensitive_logging
