import Foundation

// MARK: - VectorMath
//
// Minimal linear algebra helpers for the semantic router. We avoid pulling
// in Accelerate / BLAS since the vector counts are tiny (~200 exemplars,
// typically 50-512 dims) and the hot path runs once per query. For much
// larger corpora, replace these with vDSP calls.

enum VectorMath {
    /// Dot product of two equal-length vectors.
    @inlinable
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vector dimensions must match: \(a.count) vs \(b.count)")
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    /// L2 norm (Euclidean length).
    @inlinable
    static func l2Norm(_ v: [Float]) -> Float {
        var sum: Float = 0
        for x in v { sum += x * x }
        return sum.squareRoot()
    }

    /// In-place L2 normalization. Safe on zero vectors (returns unchanged).
    static func l2Normalize(_ v: inout [Float]) {
        let n = l2Norm(v)
        guard n > 1e-9 else { return }
        for i in 0..<v.count { v[i] /= n }
    }

    /// Produce a new L2-normalized copy.
    static func l2Normalized(_ v: [Float]) -> [Float] {
        var out = v
        l2Normalize(&out)
        return out
    }

    /// Cosine similarity ∈ [-1, 1]. Higher = more similar.
    /// Assumes BOTH vectors are already L2-normalized — pre-normalize
    /// exemplars at load time for a 2× speedup in the hot path.
    @inlinable
    static func cosineNormalized(_ a: [Float], _ b: [Float]) -> Float {
        dot(a, b)
    }

    /// Cosine similarity without the pre-normalization assumption. Slower,
    /// use only for one-off comparisons where you don't control the
    /// vector lifecycle.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let na = l2Norm(a), nb = l2Norm(b)
        guard na > 1e-9, nb > 1e-9 else { return 0 }
        return dot(a, b) / (na * nb)
    }
}
