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

// MARK: - Model Token Config

public struct ModelTokenConfig: Sendable {
    public let stopTokens: [String]
    public let stripTokens: [String]

    public static let qwen = ModelTokenConfig(
        stopTokens: ["<|im_end|>", "<|endoftext|>"],
        stripTokens: ["<|im_start|>", "<|im_end|>", "<|endoftext|>"]
    )

    public static let gemma = ModelTokenConfig(
        stopTokens: ["<end_of_turn>", "<eos>"],
        stripTokens: ["<start_of_turn>", "<end_of_turn>", "<eos>"]
    )
}

// MARK: - Inference Engine

public actor InferenceEngine {
    private let modelManager: ModelManager
    private let tokenConfig: ModelTokenConfig

    public init(modelManager: ModelManager, tokenConfig: ModelTokenConfig = .qwen) {
        self.modelManager = modelManager
        self.tokenConfig = tokenConfig
    }

    public func generate(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        let manager = self.modelManager
        let config = self.tokenConfig
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

                            // Check for stop tokens
                            if config.stopTokens.contains(where: { text.contains($0) }) {
                                var cleaned = text
                                for token in config.stripTokens {
                                    cleaned = cleaned.replacingOccurrences(of: token, with: "")
                                }
                                if !cleaned.isEmpty {
                                    fullText += cleaned
                                }
                                shouldStop = true
                                break
                            }

                            // Strip control tokens from output
                            var cleanText = text
                            for token in config.stripTokens {
                                cleanText = cleanText.replacingOccurrences(of: token, with: "")
                            }
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
