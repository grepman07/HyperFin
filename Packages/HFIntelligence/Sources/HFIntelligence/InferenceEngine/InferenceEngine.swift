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

        let _ = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: .init(prompt: request.prompt)
            )

            let parameters = GenerateParameters(
                temperature: request.temperature
            )

            var tokenCount = 0
            let result = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            ) { tokens in
                tokenCount = tokens.count
                if tokenCount >= request.maxTokens {
                    return .stop
                }

                let text = context.tokenizer.decode(tokens: tokens)
                continuation.yield(text)
                return .more
            }

            HFLogger.ai.debug("Inference complete: \(tokenCount) tokens, \(result.tokensPerSecond) tok/s")
            continuation.finish()
            return result
        }
    }
    #endif

    public func generateComplete(_ request: InferenceRequest) async throws -> String {
        var result = ""
        for try await token in generate(request) {
            result = token // MLXLMCommon yields cumulative text
        }
        return result
    }
}
