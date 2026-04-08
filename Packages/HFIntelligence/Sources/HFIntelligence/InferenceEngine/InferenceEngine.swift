import Foundation
import HFShared

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
#endif

public struct InferenceRequest: Sendable {
    public let prompt: String
    public let maxTokens: Int
    public let temperature: Float

    public init(
        prompt: String,
        maxTokens: Int = HFConstants.AI.maxGenerationTokens,
        temperature: Float = HFConstants.AI.temperature
    ) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public actor InferenceEngine {
    private let modelManager: ModelManager

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    public func generate(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        let manager = self.modelManager
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await manager.acquireInference()

                    guard await manager.isLoaded else {
                        await manager.releaseInference()
                        continuation.yield("[Model not loaded]")
                        continuation.finish()
                        return
                    }

                    guard let container = await manager.getContainer() else {
                        await manager.releaseInference()
                        continuation.finish(throwing: ModelError.modelNotLoaded)
                        return
                    }

                    HFLogger.ai.debug("Starting MLX inference (\(request.maxTokens) max tokens)")

                    let lmInput = try await container.prepare(input: UserInput(prompt: request.prompt))
                    let parameters = GenerateParameters(temperature: request.temperature)
                    let stream = try await container.generate(input: lmInput, parameters: parameters)

                    var tokenCount = 0
                    var fullText = ""
                    var shouldStop = false
                    for await generation in stream {
                        if shouldStop { break }
                        switch generation {
                        case .chunk(let text):
                            tokenCount += 1
                            if tokenCount > request.maxTokens { break }

                            // Stop on Gemma end-of-turn tokens
                            if text.contains("<end_of_turn>") || text.contains("<eos>") {
                                let cleaned = text
                                    .replacingOccurrences(of: "<end_of_turn>", with: "")
                                    .replacingOccurrences(of: "<eos>", with: "")
                                if !cleaned.isEmpty {
                                    fullText += cleaned
                                }
                                shouldStop = true
                                break
                            }

                            // Strip any other control tokens
                            let cleanText = text
                                .replacingOccurrences(of: "<start_of_turn>", with: "")
                                .replacingOccurrences(of: "<end_of_turn>", with: "")
                            fullText += cleanText
                            continuation.yield(fullText)

                        case .info(let info):
                            HFLogger.ai.debug("Inference complete: \(info.promptTokenCount) prompt tokens, \(String(format: "%.1f", info.tokensPerSecond)) tok/s")

                        default:
                            break
                        }
                    }

                    await manager.releaseInference()
                    continuation.finish()
                } catch {
                    await manager.releaseInference()
                    HFLogger.ai.error("Inference failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
        #else
        return AsyncThrowingStream { continuation in
            continuation.yield("[AI engine requires a physical device with Apple Silicon]")
            continuation.finish()
        }
        #endif
    }

    public func generateComplete(_ request: InferenceRequest) async throws -> String {
        var result = ""
        for try await token in generate(request) {
            result = token
        }
        return result
    }
}
