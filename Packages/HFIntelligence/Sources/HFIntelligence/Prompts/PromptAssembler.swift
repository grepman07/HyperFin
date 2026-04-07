import Foundation
import HFDomain
import HFShared

public struct PromptAssembler: Sendable {
    public init() {}

    public func assemble(
        userQuery: String,
        intent: ChatIntent,
        financialContext: FinancialContext,
        conversationHistory: [ChatMessage]
    ) -> String {
        var prompt = systemPrompt()
        prompt += "\n\n"

        let contextSection = buildContextSection(intent: intent, context: financialContext)
        if !contextSection.isEmpty {
            prompt += "<financial_context>\n\(contextSection)\n</financial_context>\n\n"
        }

        for message in conversationHistory.suffix(6) {
            let role = message.role == .user ? "user" : "model"
            prompt += "<start_of_turn>\(role)\n\(message.content)<end_of_turn>\n"
        }

        prompt += "<start_of_turn>user\n\(userQuery)<end_of_turn>\n"
        prompt += "<start_of_turn>model\n"

        return prompt
    }

    private func systemPrompt() -> String {
        """
        <start_of_turn>system
        You are HyperFin, a helpful and professional AI finance coach. You help users \
        understand their spending, manage budgets, and make better financial decisions.

        Guidelines:
        - Be concise and direct. Lead with the answer.
        - Use exact dollar amounts when you have financial data.
        - Be encouraging but honest about spending patterns.
        - Never give specific investment advice or recommendations to buy/sell securities.
        - If asked about something outside your data, say so clearly.
        - Format currency as $X,XXX.XX.
        - When discussing budget status, mention the percentage used.
        - You run entirely on-device. The user's financial data never leaves their iPhone.
        <end_of_turn>
        """
    }

    private func buildContextSection(intent: ChatIntent, context: FinancialContext) -> String {
        var sections: [String] = []

        if let total = context.totalSpending {
            sections.append("Total spending: \(total.currencyFormatted)")
            sections.append("Transaction count: \(context.relevantTransactions.count)")

            let topMerchants = merchantSummary(context.relevantTransactions)
            if !topMerchants.isEmpty {
                sections.append("Top merchants: \(topMerchants)")
            }
        }

        if let budget = context.currentBudget {
            sections.append("Budget month: \(budget.month)")
            sections.append("Total allocated: \(budget.totalAllocated.currencyFormatted)")
            sections.append("Total spent: \(budget.totalSpent.currencyFormatted)")
            for line in budget.lines.prefix(10) {
                let catName = context.categories.first { $0.id == line.categoryId }?.name ?? "Unknown"
                let pct = Int(line.percentUsed * 100)
                sections.append("  \(catName): \(line.spentAmount.currencyFormatted) / \(line.allocatedAmount.currencyFormatted) (\(pct)%)")
            }
        }

        if let totalBalance = context.totalBalance {
            sections.append("Total balance across accounts: \(totalBalance.currencyFormatted)")
            for account in context.accounts {
                sections.append("  \(account.accountName) (\(account.institutionName)): \(account.currentBalance.currencyFormatted)")
            }
        }

        return sections.joined(separator: "\n")
    }

    private func merchantSummary(_ transactions: [Transaction]) -> String {
        var totals: [String: Decimal] = [:]
        for txn in transactions where txn.isExpense {
            let name = txn.merchantName ?? "Unknown"
            totals[name, default: 0] += txn.amount
        }
        return totals.sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key): \($0.value.currencyFormatted)" }
            .joined(separator: ", ")
    }
}
