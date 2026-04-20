import XCTest
@testable import HFIntelligence

// MARK: - VectorMathTests
//
// Unit tests for the semantic router's vector math primitives. These are
// foundational — every routing decision depends on cosine similarity
// returning the right value.

final class VectorMathTests: XCTestCase {

    // MARK: dot

    func testDot_basic() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [4, 5, 6]
        // 1*4 + 2*5 + 3*6 = 32
        XCTAssertEqual(VectorMath.dot(a, b), 32, accuracy: 0.0001)
    }

    func testDot_zeroVectors() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 2, 3]
        XCTAssertEqual(VectorMath.dot(a, b), 0, accuracy: 0.0001)
    }

    func testDot_negativeValues() {
        let a: [Float] = [1, -2, 3]
        let b: [Float] = [-1, 2, -3]
        // -1 - 4 - 9 = -14
        XCTAssertEqual(VectorMath.dot(a, b), -14, accuracy: 0.0001)
    }

    // MARK: l2Norm

    func testL2Norm_unitVector() {
        let v: [Float] = [1, 0, 0]
        XCTAssertEqual(VectorMath.l2Norm(v), 1, accuracy: 0.0001)
    }

    func testL2Norm_3_4_5() {
        // Classic 3-4-5 triangle
        let v: [Float] = [3, 4]
        XCTAssertEqual(VectorMath.l2Norm(v), 5, accuracy: 0.0001)
    }

    func testL2Norm_zeroVector() {
        let v: [Float] = [0, 0, 0]
        XCTAssertEqual(VectorMath.l2Norm(v), 0, accuracy: 0.0001)
    }

    // MARK: l2Normalize

    func testL2Normalize_preservesDirection() {
        var v: [Float] = [3, 4]
        VectorMath.l2Normalize(&v)
        XCTAssertEqual(v[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(v[1], 0.8, accuracy: 0.0001)
        // Norm should now be 1
        XCTAssertEqual(VectorMath.l2Norm(v), 1, accuracy: 0.0001)
    }

    func testL2Normalize_zeroVectorIsNoop() {
        var v: [Float] = [0, 0, 0]
        VectorMath.l2Normalize(&v)
        // Must not divide by zero — verify unchanged
        XCTAssertEqual(v, [0, 0, 0])
    }

    // MARK: cosine

    func testCosine_identicalVectors() {
        let a: [Float] = [1, 2, 3]
        XCTAssertEqual(VectorMath.cosine(a, a), 1.0, accuracy: 0.0001)
    }

    func testCosine_orthogonal() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(VectorMath.cosine(a, b), 0.0, accuracy: 0.0001)
    }

    func testCosine_opposite() {
        let a: [Float] = [1, 0]
        let b: [Float] = [-1, 0]
        XCTAssertEqual(VectorMath.cosine(a, b), -1.0, accuracy: 0.0001)
    }

    func testCosine_zeroVectorReturnsZero() {
        let a: [Float] = [0, 0]
        let b: [Float] = [1, 0]
        // Protect against NaN when denominator would be zero
        XCTAssertEqual(VectorMath.cosine(a, b), 0.0, accuracy: 0.0001)
    }

    func testCosineNormalized_matchesCosine_whenPreNormalized() {
        let raw: [Float] = [1, 2, 3]
        let normA = VectorMath.l2Normalized(raw)
        let normB = VectorMath.l2Normalized([3, 2, 1])
        let expected = VectorMath.cosine(raw, [3, 2, 1])
        XCTAssertEqual(VectorMath.cosineNormalized(normA, normB), expected, accuracy: 0.0001)
    }
}
