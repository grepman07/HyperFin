import Foundation
import HFDomain
import HFShared

enum ClassificationError: Error {
    case noJSON
    case invalidIntent
}

struct IntentClassifier: Sendable {
    private let promptAssembler: PromptAssembler

    init(promptAssembler: PromptAssembler = PromptAssembler()) {
        self.promptAssembler = promptAssembler
    }

    func classify(
        query: String,
        slots: ConversationSlot,
        inferenceEngine: InferenceEngine
    ) async throws -> ClassificationResult {
        let messages = promptAssembler.assembleClassificationPrompt(
            query: query,
            slots: slots
        )
        let request = InferenceRequest(
            messages: messages,
            maxTokens: HFConstants.AI.classificationMaxTokens,
            temperature: HFConstants.AI.classificationTemperature
        )
        let raw = try await inferenceEngine.generateComplete(request)
        HFLogger.ai.debug("Classification raw output: \(raw)")
        return try parseClassificationJSON(from: raw)
    }

    // MARK: - JSON Parsing with 3-tier fallback

    private func parseClassificationJSON(from rawText: String) throws -> ClassificationResult {
        // Strip thinking tags (Qwen 3.5 may produce <think>...</think>)
        var cleaned = rawText
        if let thinkEnd = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[thinkEnd.upperBound...])
        }

        // Prepend "{" since the prompt primes the model with it
        let text = "{" + cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        HFLogger.ai.debug("Classification cleaned for parse: \(text.prefix(300))")

        // Tier 1: Bracket extraction + JSONDecoder
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            let jsonString = String(text[start...end])
            if let data = jsonString.data(using: .utf8) {
                if let result = try? JSONDecoder().decode(ClassificationResult.self, from: data) {
                    return result
                }
            }
        }

        // Tier 2: Regex extraction from raw text (works even with malformed JSON)
        let searchText = text
        if let match = searchText.firstMatch(of: /"intent"\s*:\s*"(\w+)"/) {
            let intentStr = String(match.1)
            let category: String? = searchText.firstMatch(of: /"category"\s*:\s*"([^"]+)"/).map { String($0.1) }
            let period: String? = searchText.firstMatch(of: /"period"\s*:\s*"([^"]+)"/).map { String($0.1) }
            let merchant: String? = searchText.firstMatch(of: /"merchant"\s*:\s*"([^"]+)"/).map { String($0.1) }
            let needsClarification = searchText.contains("\"needs_clarification\": true") ||
                                     searchText.contains("\"needsClarification\": true") ||
                                     searchText.contains("\"needs_clarification\":true")
            let clarification: String? = searchText.firstMatch(of: /"clarification"\s*:\s*"([^"]+)"/).map { String($0.1) }

            return ClassificationResult(
                intent: intentStr,
                category: category,
                merchant: merchant,
                period: period,
                needsClarification: needsClarification,
                clarification: needsClarification ? clarification : nil
            )
        }

        // Tier 2b: Check if model output contains a recognizable intent keyword directly
        let lowered = rawText.lowercased()
        let intentKeywords = ["spending", "budget", "balance", "trend", "anomaly", "advice", "greeting"]
        for keyword in intentKeywords {
            if lowered.contains(keyword) {
                HFLogger.ai.warning("Tier 2b fallback: detected intent '\(keyword)' from raw text")
                return ClassificationResult(
                    intent: keyword,
                    category: nil,
                    merchant: nil,
                    period: nil,
                    needsClarification: false,
                    clarification: nil
                )
            }
        }

        // Tier 3: Give up
        HFLogger.ai.error("Classification parse failed. Raw: \(rawText.prefix(200))")
        throw ClassificationError.noJSON
    }
}
