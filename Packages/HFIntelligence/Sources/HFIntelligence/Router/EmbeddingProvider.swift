import Foundation

// MARK: - EmbeddingProvider
//
// Abstracts over the actual embedding backend so we can swap implementations
// without touching SemanticRouter. Phase 1 uses Apple's NLEmbedding (zero
// download, iOS-native). Phase 2 can swap in a fine-tuned MLX model trained
// on real user queries from the telemetry flywheel — the router's call
// sites don't change.

public protocol EmbeddingProvider: Sendable {
    /// Produce a fixed-dimensional vector representation of the text.
    /// Throws if the backend isn't ready (not loaded, text too long, etc.)
    func embed(_ text: String) async throws -> [Float]

    /// Dimensionality of the returned vectors. Used to validate exemplar
    /// compatibility and to pre-allocate buffers.
    var dimensions: Int { get }

    /// Stable identifier — used in telemetry so we can correlate router
    /// decisions with the specific embedding model that produced them.
    var providerId: String { get }
}

// MARK: - Errors

public enum EmbeddingError: Error, Sendable, Equatable {
    case backendUnavailable(String)
    case emptyText
    case textTooLong(Int)
    case embeddingFailed(String)
}
