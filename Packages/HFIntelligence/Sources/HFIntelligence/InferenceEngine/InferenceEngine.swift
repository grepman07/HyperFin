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
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await modelManager.acquireInference()
                    defer { Task { await modelManager.releaseInference() } }

                    guard await modelManager.isLoaded else {
                        continuation.yield("[Model not loaded]")
                        continuation.finish()
                        return
                    }

                    #if canImport(MLXLLM) && !targetEnvironment(simulator)
                    try await generateWithMLX(request: request, continuation: continuation)
                    #else
                    continuation.yield("[AI engine requires a physical device with Apple Silicon]")
                    continuation.finish()
                    #endif

                } catch {
                    HFLogger.ai.error("Inference failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    #if canImport(MLXLLM) && !targetEnvironment(simulator)
    private func generateWithMLX(
        request: InferenceRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let container = await modelManager.getContainer() else {
            throw ModelError.modelNotLoaded
        }

        HFLogger.ai.debug("Starting MLX inference (\(request.maxTokens) max tokens)")

        // Prepare input using container's thread-safe convenience method
        let lmInput = try await container.prepare(input: UserInput(prompt: request.prompt))

        // Stream generation
        let parameters = GenerateParameters(temperature: request.temperature)
        let stream = try await container.generate(input: lmInput, parameters: parameters)

        var tokenCount = 0
        var fullText = ""
        for await generation in stream {
            switch generation {
            case .chunk(let text):
                tokenCount += 1
                if tokenCount > request.maxTokens { break }
                fullText += text
                continuation.yield(fullText)

            case .info(let info):
                HFLogger.ai.debug("Inference complete: \(info.promptTokenCount) prompt tokens, \(String(format: "%.1f", info.tokensPerSecond)) tok/s")

            default:
                break
            }
        }

        continuation.finish()
    }
    #endif

    public func generateComplete(_ request: InferenceRequest) async throws -> String {
        var result = ""
        for try await token in generate(request) {
            result = token
        }
        return result
    }
}
