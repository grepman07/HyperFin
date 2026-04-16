import Foundation
import HFDomain
import HFShared

public struct PromptAssembler: Sendable {
    public init() {}

    // MARK: - Planner Prompt
    //
    // The planner's job is to read the user's question and emit a JSON
    // array of tool calls that, when executed, will give the synthesizer
    // every number it needs to answer. This is the single point where
    // the model decides "what do I need to know?" — replacing the old
    // regex IntentParser + closed-set IntentClassifier pipeline.
    //
    // Prompt shape:
    //   - system: role, tool catalog, JSON shape, period vocabulary,
    //             category vocabulary, slot context carried from the
    //             previous turn (if any)
    //   - user: the raw query
    //   - assistant priming: `{"tools":[` so the model resumes inside
    //     the JSON array rather than emitting preamble text
    public func assemblePlannerPrompt(
        query: String,
        slots: ConversationSlot,
        toolCatalog: String
    ) -> [StructuredMessage] {
        var slotContext = ""
        if let cat = slots.lastCategory {
            slotContext += "\nPrevious topic: \(cat)."
        }
        if let merchant = slots.lastMerchant {
            slotContext += "\nPrevious merchant: \(merchant)."
        }
        if let period = slots.lastPeriod {
            slotContext += "\nPrevious period: \(period.humanLabel)."
        }

        let systemContent = """
        You are the planner for a personal finance assistant. The user asks a question and you decide which tools to call to gather the data needed to answer it.

        Available tools:
        \(toolCatalog)

        Respond with a JSON object of the form:
        {"tools":[{"name":"<tool_name>","args":{<arg_name>:<value>, ...}}, ...]}

        Rules:
        - Emit ONLY the JSON object, no prose, no markdown fences.
        - You may call multiple tools in one plan when a question needs data from several sources (e.g. "am I saving enough" might need net_worth + spending_summary).
        - Omit args the user didn't specify. Do not invent filters.
        - For greetings or questions unrelated to the user's finances, return {"tools":[]}.
        - If the question is about data the app does not track — live market prices, benchmarks like the S&P 500, stock recommendations ("is X a good buy"), economic forecasts, or retirement projections — return {"tools":[]}. Do NOT map the question to the nearest tool; we would rather decline honestly than answer with the wrong data.
        - Use the exact tool names from the list above. Unknown names will be rejected.

        Valid period values: today, this_week, this_month, last_month, last_30_days, last_90_days, last_N_months (e.g. last_6_months), year_to_date.

        Common spending categories: Food & Dining, Transportation, Shopping, Entertainment, Bills & Utilities, Health & Fitness, Travel, Groceries, Subscriptions, Home, Education, Personal Care, Income.

        Examples:
        Q: "What's my net worth?"
        A: {"tools":[{"name":"net_worth","args":{}}]}

        Q: "How much did I spend on groceries this month?"
        A: {"tools":[{"name":"spending_summary","args":{"category":"Groceries","period":"this_month"}}]}

        Q: "Show me every transaction over $500 this month"
        A: {"tools":[{"name":"list_transactions","args":{"min_amount":500,"period":"this_month"}}]}

        Q: "List my recent trades"
        A: {"tools":[{"name":"list_investment_transactions","args":{"activity_type":"buy","period":"last_90_days"}}]}

        Q: "What are my holdings and any dividends this year?"
        A: {"tools":[{"name":"holdings_summary","args":{}},{"name":"investment_activity","args":{"activity_type":"dividend","period":"year_to_date"}}]}

        Q: "Is AAPL a good buy?"
        A: {"tools":[]}

        Q: "How much should I have saved for retirement?"
        A: {"tools":[]}

        Q: "Hi"
        A: {"tools":[]}\(slotContext)
        """

        return [
            .system(systemContent),
            .user(query),
            // Prime with the opening of the JSON so the model continues
            // inside the array instead of emitting preamble.
            .assistant("{\"tools\":[")
        ]
    }

    // MARK: - Synthesis Prompt
    //
    // After the tools run, we hand the model the user's original question
    // PLUS the JSON-encoded tool outputs and ask it for a conversational
    // reply. If no tools ran (empty plan), the prompt is just "answer this
    // question in general terms".

    public func assembleSynthesisPrompt(
        userQuery: String,
        toolResults: [any ToolResult],
        conversationHistory: [ChatMessage],
        tone: ChatTone = .professional
    ) -> [StructuredMessage] {
        var messages: [StructuredMessage] = []
        messages.append(.system(systemPrompt(tone: tone)))

        for message in conversationHistory.suffix(2) {
            let role: StructuredMessage.Role = message.role == .user ? .user : .assistant
            messages.append(StructuredMessage(role: role, content: message.content))
        }

        // Compose the user turn as the question plus a `data:` block with
        // all tool outputs keyed by tool name. Small models copy figures
        // verbatim from structured data better than from prose.
        let dataBlock: String = {
            if toolResults.isEmpty {
                return ""
            }
            let joined = toolResults
                .map { "\"\($0.toolName)\":\($0.toJSON())" }
                .joined(separator: ",")
            return "\n\nHere is the data:\n{\(joined)}"
        }()

        messages.append(.user("\(userQuery)\(dataBlock)"))
        return messages
    }

    // MARK: - Legacy: kept for backward compat with any remaining callers.
    //
    // assembleFromToolResult used to be the only synthesis helper; it wraps
    // a single ToolResult into an array and delegates. New call sites should
    // use `assembleSynthesisPrompt` directly.
    public func assembleFromToolResult(
        userQuery: String,
        toolResult: any ToolResult,
        conversationHistory: [ChatMessage],
        tone: ChatTone = .professional
    ) -> [StructuredMessage] {
        assembleSynthesisPrompt(
            userQuery: userQuery,
            toolResults: [toolResult],
            conversationHistory: conversationHistory,
            tone: tone
        )
    }

    // MARK: - Cloud prompt flattening

    /// Flatten structured messages into a single prompt string for the
    /// cloud inference path, which handles its own message formatting.
    public func flattenForCloud(_ messages: [StructuredMessage]) -> String {
        var parts: [String] = []
        for msg in messages {
            switch msg.role {
            case .system:
                parts.append("[System]\n\(msg.content)")
            case .user:
                parts.append("[User]\n\(msg.content)")
            case .assistant:
                parts.append("[Assistant]\n\(msg.content)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Receipt Parsing Prompt

    public func assembleReceiptPrompt(ocrText: String) -> [StructuredMessage] {
        [
            .system("""
            You are a receipt parser. Extract merchant name, total amount, and date from the receipt text below.
            Respond ONLY with a JSON object. No explanation, no markdown.
            Format: {"merchant":"...","total":12.34,"date":"YYYY-MM-DD"}
            If you cannot determine a field, use null.
            """),
            .user(ocrText)
        ]
    }

    // MARK: - System Prompt

    private func systemPrompt(tone: ChatTone) -> String {
        let toneInstruction: String = switch tone {
        case .professional:
            "Be professional and clear."
        case .friendly:
            "Be warm and friendly. Use casual language."
        case .funny:
            "Be witty and humorous. Add light jokes about spending, but keep numbers accurate."
        case .strict:
            "Be strict and direct. Hold the user accountable for overspending."
        }

        // NOTE: money is already pre-formatted as human-readable strings
        // (e.g. "$142.50") inside the tool result JSON, so the model only has
        // to copy those strings verbatim. We do NOT include a literal format
        // hint in this prompt because smaller models echo it as a template.
        return """
        You are HyperFin, a personal finance coach.
        The user asks a question and you receive pre-computed data from one or more tools.
        Write a natural, conversational reply in full sentences — never output a bare number by itself.
        Only use figures that appear in the data. Never invent or estimate numbers.
        When referring to dollar amounts, copy them exactly as they appear in the data (they already include the $ sign and decimals).
        If the data shows $0.00 or 0 transactions, tell the user in a full sentence that you didn't find any matching transactions for that period. Don't just repeat the zero.
        If the data block is empty, the user asked a general finance question — answer briefly and concretely from general knowledge. Never invent user-specific numbers. If the question is about market forecasts, stock recommendations, benchmarks, or retirement projections, say "I don't have that data on device," and suggest a related question the app can answer (spending, balances, budgets, holdings, liabilities, net worth, or investment activity).
        \(toneInstruction)
        Keep responses short (2-4 sentences).
        Never mention data formats, tools, JSON, or system internals.
        """
    }
}
