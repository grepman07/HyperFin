import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - NLEmbeddingProvider
//
// Phase 1 embedding backend using Apple's NLEmbedding. Pros:
//   - Zero model download; ships with the OS
//   - Zero marginal memory cost (already resident)
//   - ~50 dim word embeddings averaged for sentence; fast on device
//   - iOS 17+ supports NLContextualEmbedding for better sentence vectors
//
// Cons:
//   - Lower semantic precision than a fine-tuned MiniLM/BGE
//   - Can't be fine-tuned on our data
//   - Apple may change the model between OS versions
//
// These trade-offs are fine for Phase 1 (cold start). Once we have telemetry
// training data, swap this out for MLXEmbeddingProvider without touching
// SemanticRouter. The EmbeddingProvider protocol is the seam.

public actor NLEmbeddingProvider: EmbeddingProvider {
    public let providerId: String = "nlembed-en-v1"
    public let dimensions: Int

    #if canImport(NaturalLanguage)
    private let embedding: NLEmbedding?
    #endif

    public init() {
        #if canImport(NaturalLanguage)
        // Use Apple's sentence embedding when available (iOS 17+), falling
        // back to word embedding averaged over tokens for older OS.
        if #available(iOS 17.0, macOS 14.0, *) {
            self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
        } else {
            self.embedding = NLEmbedding.wordEmbedding(for: .english)
        }
        self.dimensions = self.embedding?.dimension ?? 0
        #else
        self.embedding = nil
        self.dimensions = 0
        #endif
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }
        guard trimmed.count < 512 else { throw EmbeddingError.textTooLong(trimmed.count) }

        #if canImport(NaturalLanguage)
        guard let embedding else {
            throw EmbeddingError.backendUnavailable("NLEmbedding unavailable for English")
        }

        // Try sentence embedding first (iOS 17+). If that returns nil (common
        // for very short or OOV input), fall back to averaging word vectors.
        if let vector = embedding.vector(for: trimmed.lowercased()) {
            return vector.map { Float($0) }
        }

        // Word-level fallback: tokenize, fetch each word vector, mean-pool.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        var wordVectors: [[Double]] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let token = String(trimmed[range]).lowercased()
            if let v = embedding.vector(for: token) {
                wordVectors.append(v)
            }
            return true
        }

        guard !wordVectors.isEmpty else {
            throw EmbeddingError.embeddingFailed("no word vectors for: \(trimmed.prefix(40))")
        }

        let dim = wordVectors[0].count
        var mean = [Float](repeating: 0, count: dim)
        for v in wordVectors {
            for i in 0..<dim { mean[i] += Float(v[i]) }
        }
        let count = Float(wordVectors.count)
        for i in 0..<dim { mean[i] /= count }
        return mean
        #else
        throw EmbeddingError.backendUnavailable("NaturalLanguage framework not available on this platform")
        #endif
    }
}
