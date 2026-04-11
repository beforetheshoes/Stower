import Foundation
import Testing
@testable import StowerFeature

@Suite
struct ArticleRetrieverTests {
    @Test
    func emptyChunks_returnsEmpty() {
        let result = ArticleRetriever.topChunks(
            question: "anything",
            chunks: [],
            k: 5
        )
        #expect(result.isEmpty)
    }

    @Test
    func zeroK_returnsEmpty() {
        let chunks = [ArticleChunker.Chunk(index: 0, text: "hello", approxTokens: 2)]
        let result = ArticleRetriever.topChunks(
            question: "hi",
            chunks: chunks,
            k: 0
        )
        #expect(result.isEmpty)
    }

    @Test
    func fewerChunksThanK_returnsAll() {
        let chunks = [
            ArticleChunker.Chunk(index: 0, text: "cats are furry", approxTokens: 4),
            ArticleChunker.Chunk(index: 1, text: "dogs bark", approxTokens: 3),
        ]
        let result = ArticleRetriever.topChunks(
            question: "what animals are mentioned",
            chunks: chunks,
            k: 5
        )
        // Retriever returns at most `chunks.count` items. It may reorder by
        // similarity, but the full set should be present. Whether embedding
        // is available on the test host varies, so only assert the count.
        #expect(result.count == chunks.count)
        let texts = Set(result.map(\.text))
        #expect(texts.contains("cats are furry"))
        #expect(texts.contains("dogs bark"))
    }
}
