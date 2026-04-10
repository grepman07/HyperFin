import Foundation
import HFDomain
import HFShared

public actor ChatEngine {
    private let inferenceEngine: InferenceEngine
    private let cloudEngine: CloudInferenceEngine?
    private let modelManager: ModelManager
    private let intentParser: IntentParser
    private let intentClassifier: IntentClassifier
    private let promptAssembler: PromptAssembler
    private let toolDispatcher: ToolDispatcher

    /// Multi-turn slot context — persists across messages
    private var conversationSlots = ConversationSlot()

    /// The most recently resolved intent from either the regex fast-path or
    /// the LLM classifier. Exposed via `lastResolvedIntent()` so the chat view
    /// can tag telemetry events with the actual classified intent instead of
    /// re-running regex locally (which would miss LLM-only matches).
    private var _lastResolvedIntent: ChatIntent?

    public func lastResolvedIntent() -> ChatIntent? {
        _lastResolvedIntent
    }

    private var transactionRepo: TransactionRepository?
    private var categoryRepo: CategoryRepository?
    private var accountRepo: AccountRepository?
    private var budgetRepo: BudgetRepository?

    public init(
        inferenceEngine: InferenceEngine,
        modelManager: ModelManager,
        cloudEngine: CloudInferenceEngine? = nil
    ) {
        self.inferenceEngine = inferenceEngine
        self.cloudEngine = cloudEngine
        self.modelManager = modelManager
        self.intentParser = IntentParser()
        self.promptAssembler = PromptAssembler()
        self.intentClassifier = IntentClassifier()
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

    // MARK: - Hybrid Agentic Flow

    public func sendMessage(_ text: String, context: ChatContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Reset per-turn so the caller can't accidentally re-read
                    // an intent from the previous turn while this one runs.
                    self._lastResolvedIntent = nil

                    // Layer 1a: Regex fast-path
                    let regexIntent = self.intentParser.parse(text)
                    HFLogger.ai.info("Regex intent: \(String(describing: regexIntent))")

                    let resolvedIntent: ChatIntent

                    if case .unknown = regexIntent {
                        // Layer 1b: LLM classification (only when regex fails)
                        if await self.modelManager.isLoaded {
                            resolvedIntent = await self.classifyWithLLM(
                                text: text,
                                continuation: continuation
                            )
                            // If classification triggered a clarification, it already
                            // yielded the question and finished the stream
                            guard resolvedIntent != .greeting || !self.conversationSlots.pendingClarification else {
                                return
                            }
                            if self.conversationSlots.pendingClarification {
                                return
                            }
                        } else {
                            resolvedIntent = .unknown(rawQuery: text)
                        }
                    } else {
                        resolvedIntent = regexIntent
                        self.conversationSlots.updateFromRegex(regexIntent)
                    }

                    self._lastResolvedIntent = resolvedIntent

                    // Layer 2: Deterministic tool execution
                    guard let transactionRepo = self.transactionRepo,
                          let categoryRepo = self.categoryRepo,
                          let accountRepo = self.accountRepo,
                          let budgetRepo = self.budgetRepo else {
                        continuation.yield("I'm having trouble accessing your data. Please try again.")
                        continuation.finish()
                        return
                    }

                    let toolResult = try await self.toolDispatcher.dispatch(
                        intent: resolvedIntent,
                        transactionRepo: transactionRepo,
                        categoryRepo: categoryRepo,
                        accountRepo: accountRepo,
                        budgetRepo: budgetRepo
                    )

                    HFLogger.ai.info("Tool \(toolResult.toolName) returned result")

                    // Layer 3: Response generation
                    // Routing: if the user opted into cloud chat AND a cloud engine
                    // is wired up, use it. Otherwise use the local model if loaded,
                    // and finally fall back to a deterministic template response.
                    let cloudOptIn = context.userProfile?.cloudChatOptIn ?? false
                    let tone = context.userProfile?.chatTone ?? .professional
                    let messages = self.promptAssembler.assembleFromToolResult(
                        userQuery: text,
                        toolResult: toolResult,
                        conversationHistory: context.recentMessages,
                        tone: tone
                    )

                    // Local path uses structured messages so applyChatTemplate
                    // applies the model's ChatML format exactly once (no double-wrap).
                    let localRequest = InferenceRequest(messages: messages)

                    // Cloud path uses the flattened prompt string since the server
                    // handles its own message formatting via the Anthropic SDK.
                    let cloudRequest = InferenceRequest(prompt: localRequest.prompt)

                    if cloudOptIn, let cloudEngine = self.cloudEngine {
                        HFLogger.ai.info("Response generation: cloud (opted in)")
                        do {
                            for try await token in await cloudEngine.generate(cloudRequest) {
                                continuation.yield(token)
                            }
                        } catch {
                            // Graceful fallback: if the cloud call fails (network
                            // down, rate-limited, server 500), fall back to the
                            // local model if available, then to the template.
                            HFLogger.cloudChat.error("Cloud response failed, falling back: \(String(describing: error))")
                            if await self.modelManager.isLoaded {
                                for try await token in await self.inferenceEngine.generate(localRequest) {
                                    continuation.yield(token)
                                }
                            } else {
                                continuation.yield(toolResult.templateResponse(tone: tone))
                            }
                        }
                    } else if await self.modelManager.isLoaded {
                        HFLogger.ai.info("Response generation: local model")
                        for try await token in await self.inferenceEngine.generate(localRequest) {
                            continuation.yield(token)
                        }
                    } else {
                        HFLogger.ai.info("Response generation: template fallback")
                        continuation.yield(toolResult.templateResponse(tone: tone))
                    }

                    continuation.finish()
                } catch {
                    HFLogger.ai.error("Chat pipeline failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - LLM Intent Classification

    /// Uses the on-device model to classify ambiguous queries.
    /// Returns the resolved ChatIntent, or yields a clarification question and returns a sentinel.
    private func classifyWithLLM(
        text: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async -> ChatIntent {
        do {
            let classification = try await intentClassifier.classify(
                query: text,
                slots: conversationSlots,
                inferenceEngine: inferenceEngine
            )

            HFLogger.ai.info("LLM classified: \(classification.intent), clarify=\(classification.needsClarification)")

            if classification.needsClarification,
               let question = classification.clarification {
                conversationSlots.update(from: classification)
                continuation.yield(question)
                continuation.finish()
                return .greeting // sentinel — caller checks pendingClarification
            }

            let intent = resolveIntent(from: classification)
            conversationSlots.update(from: classification)
            return intent
        } catch {
            HFLogger.ai.warning("LLM classification failed: \(error), falling back to advice")
            return .generalAdvice(topic: text)
        }
    }

    // MARK: - Classification → ChatIntent Resolution

    private func resolveIntent(from result: ClassificationResult) -> ChatIntent {
        let period = resolvePeriod(result.period)

        switch result.intent {
        case "spending":
            return .spendingQuery(
                category: result.category ?? conversationSlots.lastCategory,
                merchant: result.merchant ?? conversationSlots.lastMerchant,
                period: period
            )
        case "budget":
            return .budgetStatus(category: result.category ?? conversationSlots.lastCategory)
        case "balance":
            return .accountBalance(accountName: result.merchant)
        case "trend":
            let months = extractMonths(from: result.period) ?? 3
            return .trendQuery(
                category: result.category ?? conversationSlots.lastCategory,
                months: months
            )
        case "anomaly":
            return .anomalyCheck(
                category: result.category ?? conversationSlots.lastCategory,
                period: period
            )
        case "transaction_search":
            return .transactionSearch(
                merchant: result.merchant ?? conversationSlots.lastMerchant,
                minAmount: nil,
                maxAmount: nil
            )
        case "advice":
            return .generalAdvice(topic: result.category ?? "general")
        case "greeting":
            conversationSlots.clear()
            return .greeting
        default:
            return .generalAdvice(topic: result.intent)
        }
    }

    private func resolvePeriod(_ raw: String?) -> DatePeriod {
        guard let raw else {
            return conversationSlots.lastPeriod ?? .thisMonth
        }
        switch raw {
        case "today": return .today
        case "this_week": return .thisWeek
        case "this_month": return .thisMonth
        case "last_month": return .lastMonth
        case "last_30_days": return .last30Days
        case "last_90_days": return .last90Days
        default:
            if raw.hasPrefix("last_"), raw.hasSuffix("_months") {
                let middle = raw.dropFirst(5).dropLast(7)
                if let n = Int(middle) { return .lastNMonths(n) }
            }
            return conversationSlots.lastPeriod ?? .thisMonth
        }
    }

    private func extractMonths(from period: String?) -> Int? {
        guard let period, period.hasPrefix("last_"), period.hasSuffix("_months") else {
            return nil
        }
        return Int(period.dropFirst(5).dropLast(7))
    }
}
