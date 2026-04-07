import Foundation
import HFShared

public struct InferenceRequest: Sendable {
    public let prompt: String
    public let maxTokens: Int
    public let temperature: Float
    public let stopSequences: [String]

    public init(
        prompt: String,
        maxTokens: Int = HFConstants.AI.maxGenerationTokens,
        temperature: Float = HFConstants.AI.temperature,
        stopSequences: [String] = []
    ) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
    }
}

public actor InferenceEngine {
    private let modelManager: ModelManager

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    public func generate(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await modelManager.acquireInference()
                    defer { Task { await modelManager.releaseInference() } }

                    HFLogger.ai.debug("Starting inference: \(request.prompt.prefix(100))...")

                    // Inference implementation will use MLX-Swift or Core ML.
                    // During evaluation phase, both will be prototyped here.
                    //
                    // MLX-Swift streaming:
                    //   for await token in model.generate(prompt: request.prompt, ...) {
                    //       continuation.yield(token)
                    //   }
                    //
                    // For now, yield a placeholder indicating the engine is ready
                    // but the model runtime is not yet integrated.

                    continuation.yield("[AI Engine initialized — model runtime integration pending]")
                    continuation.finish()

                } catch {
                    HFLogger.ai.error("Inference failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func generateComplete(_ request: InferenceRequest) async throws -> String {
        var result = ""
        for try await token in generate(request) {
            result += token
        }
        return result
    }
}
