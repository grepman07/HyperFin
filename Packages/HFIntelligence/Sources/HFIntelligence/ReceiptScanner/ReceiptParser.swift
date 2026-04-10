import Foundation
import HFShared

public actor ReceiptParser {
    private let inferenceEngine: InferenceEngine

    public init(inferenceEngine: InferenceEngine) {
        self.inferenceEngine = inferenceEngine
    }

    /// Parses OCR text lines into a structured ParsedReceipt using the on-device model.
    public func parse(ocrLines: [String]) async throws -> ParsedReceipt {
        let ocrText = ocrLines.joined(separator: "\n")
        let assembler = PromptAssembler()
        let messages = assembler.assembleReceiptPrompt(ocrText: ocrText)

        let request = InferenceRequest(
            messages: messages,
            maxTokens: HFConstants.AI.receiptParsingMaxTokens,
            temperature: HFConstants.AI.receiptParsingTemperature
        )

        let rawOutput = try await inferenceEngine.generateComplete(request)
        return parseJSON(from: rawOutput, ocrLines: ocrLines)
    }

    private func parseJSON(from text: String, ocrLines: [String]) -> ParsedReceipt {
        // Try to extract JSON from the response
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON object boundaries
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}") else {
            return fallbackParse(ocrLines: ocrLines)
        }

        let jsonString = String(cleaned[start...end])
        guard let data = jsonString.data(using: .utf8) else {
            return fallbackParse(ocrLines: ocrLines)
        }

        do {
            let raw = try JSONDecoder().decode(RawReceiptJSON.self, from: data)
            var receipt = ParsedReceipt()
            receipt.merchantName = raw.merchant
            receipt.totalAmount = raw.total.map { Decimal($0) }
            receipt.rawDateString = raw.date
            if let dateStr = raw.date {
                receipt.date = Self.parseDate(dateStr)
            }
            return receipt
        } catch {
            HFLogger.ai.error("Receipt JSON decode failed: \(error.localizedDescription)")
            return fallbackParse(ocrLines: ocrLines)
        }
    }

    /// Simple fallback: try to extract a total amount from the OCR lines.
    private func fallbackParse(ocrLines: [String]) -> ParsedReceipt {
        var receipt = ParsedReceipt()

        // First line is often the merchant name
        if let first = ocrLines.first, !first.isEmpty {
            receipt.merchantName = first
        }

        // Look for total amount patterns
        let totalPattern = /(?:total|amount|due|balance)[:\s]*\$?([\d,]+\.?\d{0,2})/
        for line in ocrLines.reversed() {
            if let match = line.lowercased().firstMatch(of: totalPattern) {
                let amountStr = String(match.1).replacingOccurrences(of: ",", with: "")
                receipt.totalAmount = Decimal(string: amountStr)
                break
            }
        }

        return receipt
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatters: [DateFormatter] = {
            let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "MM-dd-yyyy", "dd/MM/yyyy"]
            return formats.map { fmt in
                let f = DateFormatter()
                f.dateFormat = fmt
                return f
            }
        }()
        for formatter in formatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}

private struct RawReceiptJSON: Decodable {
    let merchant: String?
    let total: Double?
    let date: String?
}
