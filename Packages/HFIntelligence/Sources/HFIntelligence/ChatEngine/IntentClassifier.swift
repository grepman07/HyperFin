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
        let prompt = promptAssembler.assembleClassificationPrompt(
            query: query,
            slots: slots
        )
        let request = InferenceRequest(
            prompt: prompt,
            maxTokens: HFConstants.AI.classificationMaxTokens,
            temperature: HFConstants.AI.classificationTemperature
        )
        let raw = try await inferenceEngine.generateComplete(request)
        return try parseClassificationJSON(from: raw)
    }

    // MARK: - JSON Parsing with 3-tier fallback

    private func parseClassificationJSON(from rawText: String) throws -> ClassificationResult {
        // Prepend "{" since the prompt primes the model with it
        let text = "{" + rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Tier 1: Bracket extraction + JSONDecoder
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            throw ClassificationError.noJSON
        }

        let jsonString = String(text[start...end])
        guard let data = jsonString.data(using: .utf8) else {
            throw ClassificationError.noJSON
        }

        do {
            return try JSONDecoder().decode(ClassificationResult.self, from: data)
        } catch {
            // Tier 2: Regex extraction of just the intent field
            if let match = jsonString.firstMatch(of: /"intent"\s*:\s*"(\w+)"/) {
                let intentStr = String(match.1)
                // Try to extract category too
                let category: String? = jsonString.firstMatch(of: /"category"\s*:\s*"([^"]+)"/).map { String($0.1) }
                let period: String? = jsonString.firstMatch(of: /"period"\s*:\s*"([^"]+)"/).map { String($0.1) }

                return ClassificationResult(
                    intent: intentStr,
                    category: category,
                    merchant: nil,
                    period: period,
                    needsClarification: false,
                    clarification: nil
                )
            }

            // Tier 3: Give up
            throw ClassificationError.noJSON
        }
    }
}
