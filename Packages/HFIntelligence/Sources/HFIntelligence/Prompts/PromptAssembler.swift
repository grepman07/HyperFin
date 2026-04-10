import Foundation
import HFDomain
import HFShared

public struct PromptAssembler: Sendable {
    public init() {}

    // MARK: - Agentic Pattern: Tool Result → Response Generation

    /// Assemble structured messages for response generation.
    ///
    /// Returns an array of `StructuredMessage` with proper role assignments
    /// so the inference engine can pass them through `applyChatTemplate`
    /// exactly once — eliminating the double-wrapping that caused prompt
    /// echo and control-token leakage.
    public func assembleFromToolResult(
        userQuery: String,
        toolResult: any ToolResult,
        conversationHistory: [ChatMessage],
        tone: ChatTone = .professional
    ) -> [StructuredMessage] {
        var messages: [StructuredMessage] = []

        // System prompt (plain text — no ChatML markers)
        messages.append(.system(systemPrompt(tone: tone)))

        // Conversation history (limit to 2 for memory efficiency)
        for message in conversationHistory.suffix(2) {
            let role: StructuredMessage.Role = message.role == .user ? .user : .assistant
            messages.append(StructuredMessage(role: role, content: message.content))
        }

        // User query with data embedded naturally — no internal jargon
        let userContent = "\(userQuery)\n\nHere is the data:\n\(toolResult.toJSON())"
        messages.append(.user(userContent))

        return messages
    }

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

    // MARK: - Intent Classification Prompt

    public func assembleClassificationPrompt(
        query: String,
        slots: ConversationSlot
    ) -> [StructuredMessage] {
        var slotContext = ""
        if let cat = slots.lastCategory {
            slotContext += "\nPrevious topic: \(cat)."
        }
        if let merchant = slots.lastMerchant {
            slotContext += "\nPrevious merchant: \(merchant)."
        }
        if slots.pendingClarification, let intent = slots.lastIntent {
            slotContext += "\nUser is answering a clarification about: \(intent)."
        }

        let systemContent = """
        Classify the user's finance question as JSON.
        Example: {"intent":"spending","category":"Food & Dining","merchant":null,"period":"this_month","needs_clarification":false,"clarification":null}
        Valid intents: spending, budget, balance, trend, anomaly, transaction_search, advice, greeting
        Valid categories: Food & Dining, Transportation, Shopping, Entertainment, Bills & Utilities, Health & Fitness, Travel, Groceries, Subscriptions, Home, Education, Personal Care, Income
        Valid periods: today, this_week, this_month, last_month, last_30_days, last_N_months
        Reply with ONLY the JSON object.\(slotContext)
        """

        return [
            .system(systemContent),
            .user(query),
            // Prime the model with an opening brace so it continues
            // with the JSON body rather than preamble text.
            .assistant("{")
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
        The user asks a question and you receive pre-computed data.
        Write a natural, conversational reply in full sentences — never output a bare number by itself.
        Only use figures that appear in the data. Never invent or estimate numbers.
        When referring to dollar amounts, copy them exactly as they appear in the data (they already include the $ sign and decimals).
        If the data shows $0.00 or 0 transactions, tell the user in a full sentence that you didn't find any matching transactions for that period. Don't just repeat the zero.
        \(toneInstruction)
        Keep responses short (2-4 sentences).
        Never mention data formats, tools, JSON, or system internals.
        """
    }
}
