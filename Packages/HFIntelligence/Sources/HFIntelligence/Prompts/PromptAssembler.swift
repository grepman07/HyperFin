import Foundation
import HFDomain
import HFShared

public struct PromptAssembler: Sendable {
    public init() {}

    // MARK: - Agentic Pattern: Tool Result → Response Generation

    public func assembleFromToolResult(
        userQuery: String,
        toolResult: any ToolResult,
        conversationHistory: [ChatMessage],
        tone: ChatTone = .professional
    ) -> String {
        var prompt = systemPrompt(tone: tone)

        // Conversation history (limit to 2 for memory efficiency with 0.8B model)
        for message in conversationHistory.suffix(2) {
            let role = message.role == .user ? "user" : "assistant"
            prompt += "<|im_start|>\(role)\n\(message.content)<|im_end|>\n"
        }

        // User query with data embedded naturally — no internal jargon
        prompt += "<|im_start|>user\n\(userQuery)\n\nHere is the data:\n\(toolResult.toJSON())<|im_end|>\n"
        prompt += "<|im_start|>assistant\n"

        return prompt
    }

    // MARK: - Receipt Parsing Prompt

    public func assembleReceiptPrompt(ocrText: String) -> String {
        """
        <|im_start|>system
        You are a receipt parser. Extract merchant name, total amount, and date from the receipt text below.
        Respond ONLY with a JSON object. No explanation, no markdown.
        Format: {"merchant":"...","total":12.34,"date":"YYYY-MM-DD"}
        If you cannot determine a field, use null.<|im_end|>
        <|im_start|>user
        \(ocrText)<|im_end|>
        <|im_start|>assistant
        """
    }

    // MARK: - Intent Classification Prompt

    public func assembleClassificationPrompt(
        query: String,
        slots: ConversationSlot
    ) -> String {
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

        return """
        <|im_start|>system
        Classify the user's finance question. Reply ONLY with JSON, no other text.
        Intents: spending, budget, balance, trend, anomaly, transaction_search, advice, greeting
        Categories: Food & Dining, Transportation, Shopping, Entertainment, Bills & Utilities, Health & Fitness, Travel, Groceries, Subscriptions
        Periods: today, this_week, this_month, last_month, last_30_days, last_N_months
        If the query is unclear, set needs_clarification to true and write a short question.
        If the user refers to a previous topic, inherit it.\(slotContext)<|im_end|>
        <|im_start|>user
        \(query)<|im_end|>
        <|im_start|>assistant
        {
        """
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

        return """
        <|im_start|>system
        You are HyperFin, a personal finance coach.
        The user asks a question and you receive pre-computed data.
        Reply using ONLY the numbers given. Never make up numbers.
        \(toneInstruction)
        Keep responses short (2-4 sentences). Format money as $X,XXX.XX.
        Never mention data formats, tools, or system internals.<|im_end|>

        """
    }
}
