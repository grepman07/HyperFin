import Foundation
import HFDomain
import HFShared

// MARK: - ToolPlanner
//
// Turns a user query into a list of `ToolCall`s by prompting the on-device
// model, parsing its JSON output with a lenient multi-tier parser, and —
// when the model is unavailable or its output can't be parsed — falling
// back to a small keyword heuristic that ensures we still produce at
// least one reasonable tool invocation.
//
// The planner is intentionally thin. All NLU it has is the prompt; all
// domain knowledge is on the tools themselves (their descriptions). This
// is the entire replacement for the old IntentParser + IntentClassifier.

public struct ToolPlanner: Sendable {
    private let promptAssembler: PromptAssembler

    public init(promptAssembler: PromptAssembler = PromptAssembler()) {
        self.promptAssembler = promptAssembler
    }

    // MARK: - Public API

    public struct Plan: Sendable, Equatable {
        public let calls: [ToolCall]
        /// Source of the plan, useful for telemetry/debug.
        /// - `.llm`: the planner prompt parsed cleanly into calls.
        /// - `.heuristic`: the LLM was unavailable or invalid; keyword fallback matched.
        /// - `.empty`: greeting / chitchat — nothing to do, but not a refusal.
        /// - `.unsupported`: the query is recognized as out of the app's scope
        ///   (market forecasts, stock picks, retirement projections, etc.).
        ///   ChatEngine short-circuits synthesis for this case instead of
        ///   letting the LLM guess at it.
        public let source: Source

        public enum Source: String, Sendable { case llm, heuristic, semantic, empty, unsupported }

        public init(calls: [ToolCall], source: Source) {
            self.calls = calls
            self.source = source
        }
    }

    /// Generate a plan for a query. Runs a set of cheap classifiers first so
    /// greetings and obvious out-of-scope queries never reach the LLM.
    ///
    /// When `cloudEngine` is provided (user has opted into cloud chat), the
    /// planner tries it FIRST for the LLM plan — Claude Haiku is dramatically
    /// better at structured JSON output than the on-device 3B model. If the
    /// cloud call fails (network error, timeout), we fall through to the
    /// local model, then the keyword heuristic. This is the "Cloud Planning
    /// Bridge" from the architecture review.
    public func plan(
        query: String,
        slots: ConversationSlot,
        registry: ToolRegistry,
        inferenceEngine: InferenceEngine,
        cloudEngine: CloudInferenceEngine? = nil,
        semanticRouter: SemanticRouter? = nil,
        modelLoaded: Bool
    ) async -> Plan {
        // 1. Greeting short-circuit — empty plan, but NOT a refusal.
        //    This is the ONLY keyword match we keep unconditionally ahead
        //    of the semantic layer. "hi" and "hello" are so unambiguous
        //    that paying 50ms to embed them is pure waste.
        if Self.isGreeting(query) {
            return Plan(calls: [], source: .empty)
        }

        let whitelist = await Set(registry.toolNames())

        // 2. Semantic router — PRIMARY intent classifier.
        //    Gets first crack at every non-greeting query because it's the
        //    layer that actually understands semantics. The keyword OOS
        //    filter below only runs when the router can't help (cold start
        //    before prewarm, or on older iOS without NLEmbedding).
        //
        //    The router's OOS exemplars (25+ seed queries covering market
        //    forecasts, stock picks, retirement advice) handle scope
        //    refusals better than any keyword list can — they generalize
        //    to paraphrases and get smarter with telemetry-driven training.
        if let semanticRouter, await semanticRouter.isAvailable {
            let decision = await semanticRouter.route(query: query)
            switch decision {
            case .outOfScope:
                return Plan(calls: [], source: .unsupported)
            case .tool(let name, let argsHint, _):
                if whitelist.contains(name) {
                    let call = ToolCall(name: name, args: Self.convertArgsHint(argsHint))
                    return Plan(calls: [call], source: .semantic)
                }
            case .uncertain:
                break // fall through to LLM — router wasn't confident enough
            }
        } else if Self.isOutOfScope(query) {
            // 2b. ONLY when the semantic router is unavailable (cold start,
            //     unsupported platform) do we fall back to keyword-based
            //     OOS detection. This is a degraded-mode safety net, not
            //     the primary path. Even here, the keyword list is
            //     advice-specific (e.g. "save for retirement") so it
            //     doesn't false-positive on legitimate balance queries.
            return Plan(calls: [], source: .unsupported)
        }

        let catalog = await registry.catalogText()

        let messages = promptAssembler.assemblePlannerPrompt(
            query: query,
            slots: slots,
            toolCatalog: catalog
        )
        let request = InferenceRequest(
            messages: messages,
            maxTokens: HFConstants.AI.classificationMaxTokens * 3,
            temperature: HFConstants.AI.classificationTemperature
        )

        // 3. Cloud planning — try first when available. The cloud model
        //    (Claude Haiku) is far more reliable at structured JSON output
        //    than the on-device 3B model. Cost is negligible (~$0.0001/call).
        if let cloudEngine {
            do {
                // Cloud engine uses the flattened prompt string, not structured
                // messages, so build a separate request.
                let cloudRequest = InferenceRequest(
                    prompt: request.prompt,
                    maxTokens: request.maxTokens,
                    temperature: request.temperature
                )
                let raw = try await cloudEngine.generateComplete(cloudRequest)
                HFLogger.ai.debug("Cloud planner raw: \(raw.prefix(300))")
                let parsed = Self.parsePlan(raw: raw, whitelist: whitelist)
                if !parsed.isEmpty {
                    return Plan(calls: parsed, source: .llm)
                }
                HFLogger.ai.warning("Cloud planner returned empty/invalid plan, falling through to local")
            } catch {
                HFLogger.cloudChat.warning("Cloud planning failed: \(error.localizedDescription), falling through to local")
            }
        }

        // 4. Local model planning.
        if modelLoaded {
            do {
                let raw = try await inferenceEngine.generateComplete(request)
                HFLogger.ai.debug("Planner raw: \(raw.prefix(300))")
                let parsed = Self.parsePlan(raw: raw, whitelist: whitelist)
                if !parsed.isEmpty {
                    return Plan(calls: parsed, source: .llm)
                }
                HFLogger.ai.warning("Planner returned empty/invalid plan, using heuristic")
            } catch {
                HFLogger.ai.warning("Planner inference failed: \(error.localizedDescription), using heuristic")
            }
        }

        // 5. Heuristic fallback. If it also declines to match, classify the
        // turn as unsupported rather than silently answering with no data —
        // greetings were handled above, so empty here means "I tried, found
        // nothing relevant."
        let heuristic = heuristicPlan(for: query)
        return heuristic.isEmpty
            ? Plan(calls: [], source: .unsupported)
            : Plan(calls: heuristic, source: .heuristic)
    }

    // MARK: - Args hint conversion
    //
    // The semantic router's `argsHint` is a simple [String:String] because
    // the seed data is hand-written and string-typed. For numeric fields
    // (min_amount, max_amount, months, limit) we parse to the appropriate
    // ToolArgValue case so downstream tools can read them without extra
    // coercion.

    static func convertArgsHint(_ hint: [String: String]) -> [String: ToolArgValue] {
        let numericKeys: Set<String> = ["min_amount", "max_amount", "months", "limit"]
        var out: [String: ToolArgValue] = [:]
        for (k, v) in hint {
            if numericKeys.contains(k) {
                if let i = Int(v) { out[k] = .integer(i) }
                else if let d = Double(v) { out[k] = .number(d) }
                else { out[k] = .string(v) }
            } else {
                out[k] = .string(v)
            }
        }
        return out
    }

    // MARK: - Scope classifiers
    //
    // Both classifiers are static so ChatEngine tests / unit tests can call
    // them without constructing a registry or an inference engine.

    /// Return true when the query is a short friendly hello/thanks that
    /// doesn't need any tools but also isn't a refusal case.
    static func isGreeting(_ query: String) -> Bool {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.count < 30 else { return false }
        let greetings = [
            "hello", "hi", "hey", "good morning", "good afternoon",
            "good evening", "howdy", "thanks", "thank you"
        ]
        return greetings.contains(where: { lower.hasPrefix($0) })
    }

    /// Return true when the query is clearly outside HyperFin's on-device
    /// data scope — market forecasts, stock picks, retirement planning,
    /// benchmark lookups, economic predictions. The keyword list is narrow
    /// on purpose; false positives here cost us a legitimate answer, so we
    /// only match PHRASES that are almost always out of scope, not bare
    /// topic words. For example: the word "retirement" alone is NOT OOS
    /// (the user may be asking about their retirement account balance,
    /// which we can answer) — but "save for retirement" IS OOS because
    /// it's asking for advice we don't provide.
    static func isOutOfScope(_ query: String) -> Bool {
        let lower = query.lowercased()
        let phrases = [
            // Retirement ADVICE / PROJECTIONS (not balances)
            "save for retirement", "saving for retirement", "retirement planning",
            "planning for retirement", "retirement advice", "on track for retirement",
            "how much to retire", "need to retire", "when can i retire",
            "enough to retire", "ready to retire",
            // 401k / IRA ADVICE (not balances)
            "max out 401", "max out my 401", "max my 401", "maxing out 401",
            "contribute to 401", "contribute to my 401",
            "401k advice", "401(k) advice",
            "contribute to ira", "contribute to my ira",
            "max out ira", "max out my ira",
            "roth vs", "vs roth", "traditional vs", "vs traditional",
            "ira contribution",
            // Market forecasts / predictions
            "forecast", "market outlook", "s&p 500", "s & p 500",
            "projected return", "projected growth", "next year will",
            "will the market", "stock market predict", "economic predict",
            // Stock picking / advice
            "should i buy", "should i invest", "should i sell",
            "stock advice", "a good buy", "a good investment",
            "recommend a stock", "recommend me a stock", "good stock to buy",
            "is aapl a good", "is tsla a good", "is nvda a good",
            "is msft a good", "is googl a good", "is amzn a good",
            "is aapl going", "is tsla going", "is nvda going",
            // Generic financial advice
            "refinance my mortgage", "best way to build wealth",
            "how do i get out of debt"
        ]
        return phrases.contains(where: { lower.contains($0) })
    }

    // MARK: - Plan parsing (3-tier)
    //
    // Tier 1: reconstruct the full JSON object (we primed the model with
    //         `{"tools":[`) and decode via JSONSerialization. Most robust.
    // Tier 2: regex-scrape tool names + args out of malformed JSON — the
    //         model sometimes emits trailing garbage or truncates.
    // Tier 3: give up and return []. Caller falls back to heuristic.

    static func parsePlan(raw: String, whitelist: Set<String>) -> [ToolCall] {
        // Strip <think>...</think> that some Qwen builds emit.
        var cleaned = raw
        if let end = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[end.upperBound...])
        }
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // We primed the model with `{"tools":[` so prepend that back and
        // then trim to the outermost balanced object.
        let reconstructed = "{\"tools\":[\(cleaned)"

        if let calls = tier1DecodeFullJSON(from: reconstructed, whitelist: whitelist),
           !calls.isEmpty {
            return calls
        }

        if let calls = tier2RegexScrape(from: reconstructed, whitelist: whitelist),
           !calls.isEmpty {
            return calls
        }

        // Also try the raw (non-reconstructed) text in case the model
        // emitted a whole object on its own instead of continuing.
        if let calls = tier1DecodeFullJSON(from: cleaned, whitelist: whitelist),
           !calls.isEmpty {
            return calls
        }
        if let calls = tier2RegexScrape(from: cleaned, whitelist: whitelist),
           !calls.isEmpty {
            return calls
        }

        return []
    }

    private static func tier1DecodeFullJSON(
        from text: String,
        whitelist: Set<String>
    ) -> [ToolCall]? {
        // Find the outermost `{...}` slice. If the model over-ran with
        // `]}...trailing garbage`, truncate after the matching closing `}`.
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = text.index(after: i)
        }
        guard let end else { return nil }
        let jsonSlice = String(text[start...end])

        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolsArray = obj["tools"] as? [[String: Any]] else {
            return nil
        }

        var calls: [ToolCall] = []
        for entry in toolsArray {
            guard let name = entry["name"] as? String, whitelist.contains(name) else { continue }
            let rawArgs = (entry["args"] as? [String: Any]) ?? [:]
            var args: [String: ToolArgValue] = [:]
            for (k, v) in rawArgs {
                if let arg = ToolArgValue.from(any: v) {
                    args[k] = arg
                }
            }
            calls.append(ToolCall(name: name, args: args))
        }
        return calls
    }

    private static func tier2RegexScrape(
        from text: String,
        whitelist: Set<String>
    ) -> [ToolCall]? {
        // Match each `"name":"<tool>"` and the following `"args":{...}` block.
        // This is deliberately loose — it survives unclosed braces, extra
        // whitespace, and trailing commas.
        let namePattern = /"name"\s*:\s*"([a-z_][a-z0-9_]*)"(?:\s*,\s*"args"\s*:\s*(\{[^}]*\}))?/
        let nameMatches = text.matches(of: namePattern)
        var calls: [ToolCall] = []
        for m in nameMatches {
            let toolName = String(m.1)
            guard whitelist.contains(toolName) else { continue }
            var args: [String: ToolArgValue] = [:]
            if let argsBlock = m.2 {
                args = parseArgsBlock(String(argsBlock))
            }
            calls.append(ToolCall(name: toolName, args: args))
        }
        return calls.isEmpty ? nil : calls
    }

    /// Best-effort key/value extraction for a `{...}` args block. Tries
    /// strict JSON first; if that fails, regex-matches `"k":"v"` and
    /// `"k":123` pairs.
    private static func parseArgsBlock(_ text: String) -> [String: ToolArgValue] {
        if let data = text.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [String: ToolArgValue] = [:]
            for (k, v) in dict {
                if let a = ToolArgValue.from(any: v) { out[k] = a }
            }
            return out
        }

        // Fallback regex
        var out: [String: ToolArgValue] = [:]
        let strPattern = /"([a-zA-Z_][a-zA-Z0-9_]*)"\s*:\s*"([^"]*)"/
        for m in text.matches(of: strPattern) {
            out[String(m.1)] = .string(String(m.2))
        }
        let numPattern = /"([a-zA-Z_][a-zA-Z0-9_]*)"\s*:\s*(-?\d+(?:\.\d+)?)/
        for m in text.matches(of: numPattern) {
            let key = String(m.1)
            if out[key] != nil { continue } // strings already captured
            let numStr = String(m.2)
            if let i = Int(numStr) {
                out[key] = .integer(i)
            } else if let d = Double(numStr) {
                out[key] = .number(d)
            }
        }
        let boolPattern = /"([a-zA-Z_][a-zA-Z0-9_]*)"\s*:\s*(true|false)/
        for m in text.matches(of: boolPattern) {
            out[String(m.1)] = .boolean(String(m.2) == "true")
        }
        return out
    }

    // MARK: - Heuristic fallback
    //
    // The heuristic is NOT the primary NLU anymore — it only runs when the
    // model is unavailable or mis-plans. It deliberately over-prefers
    // `spending_summary` since that's the most common question, and leaves
    // period/category blank so the tool uses its own defaults.

    func heuristicPlan(for query: String) -> [ToolCall] {
        let lower = query.lowercased()

        // Greetings / help — no tools needed. The planner's main `plan`
        // entry point short-circuits greetings before calling us, but keep
        // this check so the function is safe to call directly from tests.
        if Self.isGreeting(query) { return [] }

        // Net worth family.
        if lower.contains("net worth")
            || lower.contains("how much am i worth")
            || lower.contains("my assets")
            || lower.contains("how rich")
            || lower.contains("am i a millionaire") {
            return [ToolCall(name: "net_worth", args: [:])]
        }

        // Liabilities / debt.
        if lower.contains("owe") || lower.contains("debt") || lower.contains("liabilities")
            || lower.contains("credit card") || lower.contains("mortgage")
            || lower.contains("student loan") {
            let kind: String? = {
                if lower.contains("credit card") { return "credit" }
                if lower.contains("mortgage") { return "mortgage" }
                if lower.contains("student loan") { return "student" }
                return nil
            }()
            var args: [String: ToolArgValue] = [:]
            if let k = kind { args["kind"] = .string(k) }
            return [ToolCall(name: "liability_report", args: args)]
        }

        // Holdings / portfolio / specific tickers.
        if lower.contains("holdings") || lower.contains("portfolio")
            || lower.contains("stocks") || lower.contains("brokerage")
            || lower.contains("investments") || lower.contains("crypto")
            || lower.contains("bitcoin") || lower.contains("ethereum") {
            return [ToolCall(name: "holdings_summary", args: [:])]
        }

        // Ticker-style questions: "how much BTC/AAPL/TSLA do I have?"
        // Match 2-5 uppercase letter sequences that look like tickers.
        if let ticker = extractTicker(from: query) {
            return [ToolCall(name: "holdings_summary", args: ["ticker": .string(ticker)])]
        }

        // Investment activity.
        if lower.contains("dividend") {
            return [ToolCall(name: "investment_activity",
                             args: ["activity_type": .string("dividend")])]
        }
        if lower.contains("trade") || lower.contains("buy") || lower.contains("sell") {
            return [ToolCall(name: "investment_activity", args: [:])]
        }

        // Budget.
        if lower.contains("budget") || lower.contains("over budget")
            || lower.contains("under budget") {
            return [ToolCall(name: "budget_status", args: [:])]
        }

        // Balance.
        if lower.contains("balance") || lower.contains("checking")
            || lower.contains("savings account") {
            return [ToolCall(name: "account_balance", args: [:])]
        }

        // Trend.
        if lower.contains("trend") || lower.contains("over time")
            || lower.contains("changed") {
            return [ToolCall(name: "spending_trend", args: [:])]
        }

        // Anomaly.
        if lower.contains("unusual") || lower.contains("spike")
            || lower.contains("higher than usual") {
            return [ToolCall(name: "spending_anomaly", args: [:])]
        }

        // Default: treat it as a spending question — but ONLY when the
        // query explicitly mentions spending/cost/expense. Previously
        // `"how much"` was in this list, which greedily caught questions
        // like "how much should I save for retirement?" and mis-routed
        // them. The out-of-scope detector in `plan(...)` catches retirement
        // queries first; dropping `"how much"` here keeps this fallback
        // honest when the OOS detector misses.
        if lower.contains("spend") || lower.contains("spent")
            || lower.contains("cost")
            || lower.contains("expense") {
            return [ToolCall(name: "spending_summary", args: [:])]
        }

        return []
    }

    // MARK: - Ticker extraction

    /// Pull a likely ticker symbol out of a query like "how much BTC do I
    /// have?" or "show me my AAPL". We look for 1-5 uppercase letters that
    /// aren't common English words. This only fires in the heuristic path
    /// (model unavailable or mis-planned), so false positives are low-cost —
    /// they just route to `holdings_summary` which returns an empty result
    /// if the ticker doesn't match any holding.
    private func extractTicker(from query: String) -> String? {
        // Common short uppercase words that aren't tickers.
        let stopWords: Set<String> = [
            "I", "A", "AM", "AN", "AS", "AT", "BE", "BY", "DO", "GO",
            "IF", "IN", "IS", "IT", "ME", "MY", "NO", "OF", "OK", "ON",
            "OR", "SO", "TO", "UP", "US", "WE", "THE", "AND", "ARE",
            "BUT", "CAN", "DID", "FOR", "GET", "GOT", "HAS", "HAD",
            "HER", "HIM", "HIS", "HOW", "ITS", "LET", "MAY", "NOT",
            "NOW", "OLD", "OUR", "OUT", "OWN", "PUT", "RAN", "SAY",
            "SHE", "TOO", "USE", "WAS", "WAY", "WHO", "WHY", "YES",
            "YET", "YOU", "HAVE", "MUCH", "WHAT", "WITH", "FROM",
            "SHOW", "TELL", "THAT", "THIS", "DOES", "WILL"
        ]

        let words = query.components(separatedBy: .whitespacesAndNewlines)
        for word in words {
            // Strip trailing punctuation ("BTC?" → "BTC")
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            guard (1...5).contains(cleaned.count),
                  cleaned == cleaned.uppercased(),
                  cleaned.allSatisfy({ $0.isLetter }),
                  !stopWords.contains(cleaned) else { continue }
            return cleaned
        }
        return nil
    }
}
