import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct ArticleChunkerTests {
    @Test
    func emptyInput_returnsEmptyChunks() {
        let chunks = ArticleChunker.chunks(
            from: nil,
            plainText: "",
            budgetTokens: 100
        )
        #expect(chunks.isEmpty)
    }

    @Test
    func smallPlainText_fitsInSingleChunkWhenNoDocument() {
        let chunks = ArticleChunker.chunks(
            from: nil,
            plainText: "One paragraph.\n\nAnother paragraph.",
            budgetTokens: 1000
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("One paragraph."))
        #expect(chunks[0].text.contains("Another paragraph."))
    }

    @Test
    func largeDocument_splitsOnBlockBoundaries() {
        // Each block is ~25 chars ≈ 7 tokens via approx counter; budget of 15
        // tokens should group ~2 blocks per chunk.
        let blocks: [ReaderBlock] = (0..<6).map { i in
            .paragraph([.text("Paragraph number \(i) here.")])
        }
        let document = ReaderDocument(title: "Test", blocks: blocks)

        let chunks = ArticleChunker.chunks(
            from: document,
            plainText: "",
            budgetTokens: 15
        )

        #expect(chunks.count > 1, "Expected multiple chunks but got \(chunks.count)")
        for chunk in chunks {
            #expect(chunk.approxTokens <= 15 || chunk.text.contains("\n\n"),
                    "Chunk \(chunk.index) exceeds budget without a block split")
        }

        // All content should be present across the chunks.
        let combined = chunks.map(\.text).joined(separator: " ")
        for i in 0..<6 {
            #expect(combined.contains("Paragraph number \(i)"))
        }
    }

    @Test
    func oversizedSingleBlock_sentenceSplits() {
        // One long block whose single text exceeds the budget — chunker should
        // fall through to sentence-level splitting.
        let longText = String(repeating: "Sentence one runs here. Sentence two follows. ", count: 20)
        let document = ReaderDocument(
            title: "Test",
            blocks: [.paragraph([.text(longText)])]
        )

        let chunks = ArticleChunker.chunks(
            from: document,
            plainText: "",
            budgetTokens: 30
        )

        #expect(chunks.count > 1, "Expected sentence-split chunks")
        // Every non-final chunk should be within (or very close to) budget.
        for chunk in chunks.dropLast() {
            #expect(chunk.approxTokens <= 60,
                    "Chunk approx tokens = \(chunk.approxTokens); should respect budget")
        }
    }

    @Test
    func approxTokenCount_scalesWithLength() {
        #expect(ArticleChunker.approxTokenCount("") == 0)
        // 3 chars-per-token conservative estimate:
        // "hello" is 5 chars → (5+2)/3 = 2 tokens
        #expect(ArticleChunker.approxTokenCount("hello") == 2)
        // 100-char string → (100+2)/3 = 34 tokens
        let s = String(repeating: "a", count: 100)
        #expect(ArticleChunker.approxTokenCount(s) == 34)
    }
}
