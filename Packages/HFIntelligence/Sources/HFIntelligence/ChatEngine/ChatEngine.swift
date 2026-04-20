import Foundation
import HFDomain
import HFShared

// MARK: - ChatEngine
//
// The chat pipeline is now a tool-calling loop:
//
//     Plan (LLM)  →  Execute (parallel)  →  Synthesize (LLM, streaming)
//
// - Plan: `ToolPlanner` prompts the model with the tool catalog + user
//   query; output is a list of `ToolCall`s.
// - Execute: `ToolRegistry` runs each call. Independent calls are fanned
//   out with `withThrowingTaskGroup` so a multi-tool plan doesn't block
//   on sequential SwiftData reads.
// - Synthesize: the model streams a natural-language reply grounded in
//   the aggregated tool outputs. Cloud engine is used when the user has
//   opted in; local model is used otherwise; if neither is available the
//   engine falls back to concatenating the tools' own `templateResponse`.
//
// The previous pipeline's regex IntentParser + closed-set IntentClassifier
// + switch-per-intent ToolDispatcher are gone — all replaced by this one
// loop plus the catalog-driven prompt.

public actor ChatEngine {
    private let inferenceEngine: InferenceEngine
    private let cloudEngine: CloudInferenceEngine?
    private let modelManager: ModelManager
    private let registry: ToolRegistry
    private let planner: ToolPlanner
    private let promptAssembler: PromptAssembler
    /// Optional semantic router — when present and ready, the planner
    /// consults it before falling back to the LLM. Nil is safe (pipeline
    /// just skips the semantic step).
    private let semanticRouter: SemanticRouter?

    /// Per-conversation slot state carried from one turn to the next.
    /// The planner prompt references these as "Previous topic/merchant/period"
    /// so follow-ups like "what about last month?" still work.
    private var conversationSlots = ConversationSlot()

    /// Names of tools executed on the most recent turn. Exposed to the view
    /// model for telemetry tagging. Empty when the turn was a greeting /
    /// general-advice reply with no tools.
    private var _lastToolNames: [String] = []

    /// The plan source of the most recent turn ("llm", "semantic",
    /// "heuristic", "empty", "unsupported"). Feeds the data flywheel —
    /// we need to know which routing tier answered so we can measure each
    /// tier's accuracy against shadow-evaluated ground truth.
    private var _lastPlanSource: String = ""

    /// Raw plan JSON from the most recent turn. Server-side uses this for
    /// shadow evaluation and to derive training pairs. Empty string for
    /// turns that didn't go through a planner (canned replies, greetings).
    private var _lastPlanJSON: String = ""

    public func lastToolNames() -> [String] { _lastToolNames }
    public func lastPlanSource() -> String { _lastPlanSource }
    public func lastPlanJSON() -> String { _lastPlanJSON }

    public init(
        inferenceEngine: InferenceEngine,
        modelManager: ModelManager,
        registry: ToolRegistry,
        cloudEngine: CloudInferenceEngine? = nil,
        semanticRouter: SemanticRouter? = nil
    ) {
        self.inferenceEngine = inferenceEngine
        self.cloudEngine = cloudEngine
        self.modelManager = modelManager
        self.registry = registry
        self.planner = ToolPlanner()
        self.promptAssembler = PromptAssembler()
        self.semanticRouter = semanticRouter
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

    // MARK: - Entry point

    public func sendMessage(_ text: String, context: ChatContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    self._lastToolNames = []
                    self._lastPlanSource = ""
                    self._lastPlanJSON = ""

                    // 1. PLAN
                    // Pass cloudEngine to planner when user has opted in.
                    // The planner tries cloud first (better JSON quality),
                    // then local model, then keyword heuristic.
                    let modelLoaded = await self.modelManager.isLoaded
                    let cloudOptIn = context.userProfile?.cloudChatOptIn ?? false
                    let plannerCloud = cloudOptIn ? self.cloudEngine : nil
                    let plan = await self.planner.plan(
                        query: text,
                        slots: self.conversationSlots,
                        registry: self.registry,
                        inferenceEngine: self.inferenceEngine,
                        cloudEngine: plannerCloud,
                        semanticRouter: self.semanticRouter,
                        modelLoaded: modelLoaded
                    )
                    HFLogger.ai.info("Plan[\(plan.source.rawValue)]: \(plan.calls.map(\.name).joined(separator: ","))")
                    self._lastPlanSource = plan.source.rawValue
                    self._lastPlanJSON = Self.encodePlanJSON(plan)

                    // 2. EXECUTE (parallel)
                    let results = try await self.executeAll(plan.calls)
                    self._lastToolNames = results.map { $0.toolName }

                    // 3. SYNTHESIZE
                    try await self.synthesize(
                        userQuery: text,
                        toolResults: results,
                        plan: plan,
                        context: context,
                        continuation: continuation
                    )

                    // Update slot state with whatever the planner extracted
                    // (first call wins for each slot) so follow-ups carry it.
                    self.absorbSlotsFrom(plan: plan)

                    continuation.finish()
                } catch {
                    HFLogger.ai.error("Chat pipeline failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Execute (parallel tool run)

    /// Fan out all tool calls in parallel and collect their results in the
    /// original order. Individual tool failures are logged and dropped so
    /// one broken tool doesn't sink the whole turn — if every tool fails,
    /// synthesize() will notice the empty result list and route to a
    /// general-advice reply.
    private func executeAll(_ calls: [ToolCall]) async throws -> [any ToolResult] {
        guard !calls.isEmpty else { return [] }

        // Keep (index, result) so we can restore the order the planner
        // emitted — important when two tools both affect the prose (e.g.
        // net_worth + spending_summary — netting first reads better).
        return try await withThrowingTaskGroup(of: (Int, (any ToolResult)?).self) { group in
            for (idx, call) in calls.enumerated() {
                let registry = self.registry
                group.addTask {
                    do {
                        let result = try await registry.execute(call)
                        return (idx, result)
                    } catch {
                        HFLogger.ai.warning("Tool '\(call.name)' failed: \(error.localizedDescription)")
                        return (idx, nil)
                    }
                }
            }

            var collected: [(Int, any ToolResult)] = []
            for try await (idx, result) in group {
                if let result { collected.append((idx, result)) }
            }
            collected.sort { $0.0 < $1.0 }
            return collected.map { $0.1 }
        }
    }

    // MARK: - Synthesize

    private func synthesize(
        userQuery: String,
        toolResults: [any ToolResult],
        plan: ToolPlanner.Plan,
        context: ChatContext,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let cloudOptIn = context.userProfile?.cloudChatOptIn ?? false
        let tone = context.userProfile?.chatTone ?? .professional

        // Out-of-scope queries never reach the LLM. The planner explicitly
        // classified this as "data we don't have on device" — let the model
        // loose on it and it will happily invent an answer, so we emit a
        // canned, tone-aware decline instead. Cheaper, more reliable, and
        // the one place hallucination risk is most dangerous (users take
        // "your retirement target is $X" as authoritative).
        if plan.source == .unsupported {
            HFLogger.ai.info("Synthesis: unsupported (canned reply)")
            continuation.yield(Self.unsupportedReply(tone: tone))
            return
        }

        // Build the synthesis prompt regardless of which engine we use —
        // the messages are identical; only the transport differs.
        let messages = promptAssembler.assembleSynthesisPrompt(
            userQuery: userQuery,
            toolResults: toolResults,
            conversationHistory: context.recentMessages,
            tone: tone
        )
        let localRequest = InferenceRequest(messages: messages)
        let cloudRequest = InferenceRequest(prompt: localRequest.prompt)

        // Cloud path.
        if cloudOptIn, let cloudEngine = self.cloudEngine {
            HFLogger.ai.info("Synthesis: cloud (opted in)")
            do {
                for try await token in await cloudEngine.generate(cloudRequest) {
                    continuation.yield(token)
                }
                return
            } catch {
                HFLogger.cloudChat.error("Cloud synthesis failed, falling back: \(String(describing: error))")
                // fall through
            }
        }

        // Local path.
        if await modelManager.isLoaded {
            HFLogger.ai.info("Synthesis: local model")
            for try await token in await inferenceEngine.generate(localRequest) {
                continuation.yield(token)
            }
            return
        }

        // Template fallback — no model available. Concatenate each tool's
        // own template response. If the plan was empty (e.g. greeting), use
        // a generic copy message.
        HFLogger.ai.info("Synthesis: template fallback")
        if toolResults.isEmpty {
            continuation.yield(Self.defaultTemplateReply(for: userQuery, tone: tone))
        } else {
            let parts = toolResults.map { $0.templateResponse(tone: tone) }
            continuation.yield(parts.joined(separator: "\n\n"))
        }
    }

    /// Tone-aware canned reply for `.unsupported` plans — queries the app
    /// explicitly cannot answer from on-device data (market forecasts, stock
    /// picks, retirement projections, benchmarks). Emitted without calling
    /// the model: cheaper, zero hallucination risk, and a predictable honest
    /// decline is the right product behavior here.
    private static func unsupportedReply(tone: ChatTone) -> String {
        let capabilities = "I can help with spending, balances, budgets, holdings, liabilities, net worth, and investment activity."
        switch tone {
        case .professional:
            return "That's outside what I can answer from your on-device data. \(capabilities)"
        case .friendly:
            return "That one's outside what I can see from your accounts. \(capabilities)"
        case .funny:
            return "Crystal ball's in the shop — I can't forecast markets or pick stocks. \(capabilities)"
        case .strict:
            return "I don't answer questions outside your on-device data. \(capabilities)"
        }
    }

    /// Serialize a plan to a compact JSON string for telemetry. Matches the
    /// shape the planner LLM produces so server-side analysis can compare
    /// directly against shadow-evaluated ground truth. Returns "" for
    /// plans with no tool calls (greetings, unsupported) so we don't waste
    /// bytes uploading empty structures.
    static func encodePlanJSON(_ plan: ToolPlanner.Plan) -> String {
        guard !plan.calls.isEmpty else { return "" }
        var parts: [String] = []
        for call in plan.calls {
            let argsJSON = encodeArgs(call.args)
            parts.append("{\"name\":\"\(call.name)\",\"args\":\(argsJSON)}")
        }
        return "{\"tools\":[\(parts.joined(separator: ","))]}"
    }

    private static func encodeArgs(_ args: [String: ToolArgValue]) -> String {
        if args.isEmpty { return "{}" }
        // Sort keys so the serialized form is stable across runs — makes
        // diffing shadow-eval output deterministic.
        let sorted = args.sorted { $0.key < $1.key }
        let pairs = sorted.map { (k, v) -> String in
            "\"\(k)\":\(encodeArgValue(v))"
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    private static func encodeArgValue(_ v: ToolArgValue) -> String {
        switch v {
        case .string(let s):
            // Escape quotes and backslashes — minimal JSON-safe encoding.
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .integer(let i): return "\(i)"
        case .number(let d): return "\(d)"
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func defaultTemplateReply(for query: String, tone: ChatTone) -> String {
        let lower = query.lowercased()
        if ["hi", "hello", "hey"].contains(where: { lower.hasPrefix($0) }) {
            switch tone {
            case .professional: return "Hello. How can I help you with your finances today?"
            case .friendly: return "Hey! How can I help with your finances today?"
            case .funny: return "Well hello there! Ready to make your money beg for mercy?"
            case .strict: return "Hello. State your finance question and I will respond."
            }
        }
        return "I can help with spending, budgets, balances, trends, holdings, liabilities, net worth, and investment activity. Try asking \"what's my net worth\" or \"how much did I spend on groceries\"."
    }

    // MARK: - Slot tracking

    /// Record any category/merchant/period the planner used so follow-up
    /// turns like "what about last month?" pick them up. First call wins —
    /// when multiple tools fire, we trust whatever the primary intent was.
    private func absorbSlotsFrom(plan: ToolPlanner.Plan) {
        // Empty plan => greeting-like; clear slots so the next turn starts
        // fresh rather than re-using stale context from before the chit-chat.
        guard let first = plan.calls.first else {
            if plan.source == .empty { conversationSlots.clear() }
            return
        }

        switch first.name {
        case "spending_summary":
            if let cat = first.args.string("category") { conversationSlots.lastCategory = cat }
            if let merchant = first.args.string("merchant") { conversationSlots.lastMerchant = merchant }
            conversationSlots.lastPeriod = first.args.period("period", defaultTo: .thisMonth)
            conversationSlots.lastIntent = "spending"
        case "budget_status":
            if let cat = first.args.string("category") { conversationSlots.lastCategory = cat }
            conversationSlots.lastIntent = "budget"
        case "account_balance":
            conversationSlots.lastIntent = "balance"
        case "transaction_search":
            if let m = first.args.string("merchant") { conversationSlots.lastMerchant = m }
            conversationSlots.lastIntent = "transaction_search"
        case "spending_trend":
            if let cat = first.args.string("category") { conversationSlots.lastCategory = cat }
            conversationSlots.lastIntent = "trend"
        case "spending_anomaly":
            if let cat = first.args.string("category") { conversationSlots.lastCategory = cat }
            conversationSlots.lastPeriod = first.args.period("period", defaultTo: .thisMonth)
            conversationSlots.lastIntent = "anomaly"
        case "holdings_summary":
            if let t = first.args.string("ticker") { conversationSlots.lastMerchant = t }
            conversationSlots.lastIntent = "holdings"
        case "liability_report":
            if let k = first.args.string("kind") { conversationSlots.lastCategory = k }
            conversationSlots.lastIntent = "liabilities"
        case "net_worth":
            conversationSlots.lastIntent = "net_worth"
        case "investment_activity":
            if let t = first.args.string("activity_type") { conversationSlots.lastCategory = t }
            conversationSlots.lastPeriod = first.args.period("period", defaultTo: .lastNMonths(3))
            conversationSlots.lastIntent = "investment_activity"
        default:
            break
        }
        conversationSlots.pendingClarification = false
    }
}
