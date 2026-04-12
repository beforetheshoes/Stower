import Foundation
import NaturalLanguage

/// Retrieves the top-k most relevant chunks for a question using NLEmbedding
/// sentence vectors. Used by the Q&A path when an article is too long to
/// stuff into a single Foundation Models context window.
///
/// v1 is per-question and in-memory: the embedding is computed for each
/// chunk on every Ask call. If latency becomes a problem on very long
/// articles, this can be cached per itemID inside the AI client.
public enum ArticleRetriever {
    public static func topChunks(
        question: String,
        chunks: [ArticleChunker.Chunk],
        k: Int = 5
    ) -> [ArticleChunker.Chunk] {
        guard !chunks.isEmpty else { return [] }
        guard k > 0 else { return [] }

        // `sentenceEmbedding` is available for a limited set of languages. If
        // the default isn't installed (older devices, uncommon region), fall
        // back to returning the leading chunks rather than failing.
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return Array(chunks.prefix(k))
        }

        guard let questionVector = sentenceAveragedVector(for: question, embedding: embedding) else {
            return Array(chunks.prefix(k))
        }

        // swiftlint:disable:next prefer_let_over_var
        var scored: [(chunk: ArticleChunker.Chunk, score: Double)] = []
        scored.reserveCapacity(chunks.count)

        for chunk in chunks {
            guard let chunkVector = sentenceAveragedVector(for: chunk.text, embedding: embedding) else {
                continue
            }
            let score = cosineSimilarity(questionVector, chunkVector)
            scored.append((chunk, score))
        }

        guard !scored.isEmpty else {
            return Array(chunks.prefix(k))
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(k).map { $0.chunk })
    }

    /// Returns a vector for `text` that handles both short phrases and
    /// paragraph-sized chunks. `NLEmbedding.sentenceEmbedding.vector(for:)`
    /// is tuned for short inputs; on long inputs it sometimes returns a
    /// low-quality vector or nil. This helper splits the input into
    /// sentences via `NLTokenizer`, embeds each one, and returns the mean
    /// of the sentence vectors. Falls back to the whole-text embedding if
    /// tokenization produces nothing usable.
    private static func sentenceAveragedVector(for text: String, embedding: NLEmbedding) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sentences = splitSentences(trimmed)

        // Short input: just embed directly.
        if sentences.count <= 1 {
            if let vec = embedding.vector(for: trimmed), !vec.isEmpty {
                return vec
            }
            return nil
        }

        // swiftlint:disable:next prefer_let_over_var
        var sum: [Double] = []
        var count = 0

        for sentence in sentences {
            guard let vec = embedding.vector(for: sentence), !vec.isEmpty else { continue }
            if sum.isEmpty {
                sum = vec
            } else {
                let n = min(sum.count, vec.count)
                for i in 0..<n { sum[i] += vec[i] }
            }
            count += 1
        }

        guard count > 0 else {
            // Every sentence failed individually — one last try on the whole.
            if let vec = embedding.vector(for: trimmed), !vec.isEmpty {
                return vec
            }
            return nil
        }

        let divisor = Double(count)
        for i in 0..<sum.count { sum[i] /= divisor }
        return sum
    }

    private static func splitSentences(_ text: String) -> [String] {
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

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }

        var dot = 0.0
        var magA = 0.0
        var magB = 0.0
        for i in 0..<count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
}
