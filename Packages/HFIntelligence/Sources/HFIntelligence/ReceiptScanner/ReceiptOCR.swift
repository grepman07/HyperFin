import Foundation
import Vision
import UIKit

public struct ReceiptOCR: Sendable {

    public init() {}

    /// Runs Apple Vision OCR on a UIImage and returns recognized text lines sorted top-to-bottom.
    public func recognizeText(from image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else {
            throw ReceiptScanError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                // Sort by vertical position (top to bottom)
                let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }

                let lines = sorted.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }

                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum ReceiptScanError: Error, LocalizedError {
    case invalidImage
    case ocrFailed(String)
    case parseFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "Could not process the image."
        case .ocrFailed(let msg): "OCR failed: \(msg)"
        case .parseFailed: "Could not extract receipt details."
        }
    }
}
