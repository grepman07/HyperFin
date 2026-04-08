import Foundation
import HFDomain
import HFShared

public actor ChatEngine {
    private let inferenceEngine: InferenceEngine
    private let modelManager: ModelManager
    private let intentParser: IntentParser
    private let promptAssembler: PromptAssembler
    private let toolDispatcher: ToolDispatcher

    private var transactionRepo: TransactionRepository?
    private var categoryRepo: CategoryRepository?
    private var accountRepo: AccountRepository?
    private var budgetRepo: BudgetRepository?

    public init(
        inferenceEngine: InferenceEngine,
        modelManager: ModelManager
    ) {
        self.inferenceEngine = inferenceEngine
        self.modelManager = modelManager
        self.intentParser = IntentParser()
        self.promptAssembler = PromptAssembler()
        self.toolDispatcher = ToolDispatcher()
    }

    public func setRepositories(
        transactions: TransactionRepository,
        categories: CategoryRepository,
        accounts: AccountRepository,
        budgets: BudgetRepository
    ) {
        self.transactionRepo = transactions
        self.categoryRepo = categories
        self.accountRepo = accounts
        self.budgetRepo = budgets
    }

    public var isModelAvailable: Bool {
        get async { await modelManager.isLoaded }
    }

    public var modelStatus: ModelStatus {
        get async { await modelManager.currentStatus }
    }

    public func loadModel() async throws {
        try await modelManager.loadModel()
    }

    // MARK: - 3-Layer Agentic Flow

    public func sendMessage(_ text: String, context: ChatContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Layer 1: Intent classification (regex, no model)
                    let intent = intentParser.parse(text)
                    HFLogger.ai.info("Parsed intent: \(String(describing: intent))")

                    // Layer 2: Deterministic tool execution
                    guard let transactionRepo, let categoryRepo, let accountRepo, let budgetRepo else {
                        continuation.yield("I'm having trouble accessing your data. Please try again.")
                        continuation.finish()
                        return
                    }

                    let toolResult = try await toolDispatcher.dispatch(
                        intent: intent,
                        transactionRepo: transactionRepo,
                        categoryRepo: categoryRepo,
                        accountRepo: accountRepo,
                        budgetRepo: budgetRepo
                    )

                    HFLogger.ai.info("Tool \(toolResult.toolName) returned result")

                    // Layer 3: Response generation
                    if await modelManager.isLoaded {
                        let tone = context.userProfile?.chatTone ?? .professional
                        let prompt = promptAssembler.assembleFromToolResult(
                            userQuery: text,
                            toolResult: toolResult,
                            conversationHistory: context.recentMessages,
                            tone: tone
                        )

                        let request = InferenceRequest(prompt: prompt)
                        for try await token in await inferenceEngine.generate(request) {
                            continuation.yield(token)
                        }
                    } else {
                        // Fallback: use tool result's template response (no model needed)
                        continuation.yield(toolResult.templateResponse())
                    }

                    continuation.finish()
                } catch {
                    HFLogger.ai.error("Chat pipeline failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
