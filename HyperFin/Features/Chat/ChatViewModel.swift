import Foundation
import SwiftUI
import SwiftData
import HFDomain
import HFData
import HFIntelligence
import HFShared

struct ChatMessageUI: Identifiable {
    let id: UUID
    let content: String
    let isUser: Bool
    var isStreaming: Bool

    init(id: UUID = UUID(), content: String, isUser: Bool, isStreaming: Bool = false) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.isStreaming = isStreaming
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessageUI] = [
        ChatMessageUI(
            content: "Hi! I'm HyperFin, your AI finance coach. I run entirely on your device — your financial data never leaves your iPhone.\n\nTry asking:\n- \"How much did I spend on food this month?\"\n- \"What's my balance?\"\n- \"Show my budget status\"\n- \"Find transactions from Amazon\"",
            isUser: false
        )
    ]
    var inputText = ""
    var isProcessing = false

    private let intentParser = IntentParser()
    var modelContainer: ModelContainer?

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        messages.append(ChatMessageUI(content: text, isUser: true))

        isProcessing = true
        let responseId = UUID()
        messages.append(ChatMessageUI(id: responseId, content: "", isUser: false, isStreaming: true))

        Task {
            let response = await processQuery(text)
            if let idx = messages.firstIndex(where: { $0.id == responseId }) {
                messages[idx] = ChatMessageUI(
                    id: responseId,
                    content: response,
                    isUser: false,
                    isStreaming: false
                )
            }
            isProcessing = false
        }
    }

    private func processQuery(_ text: String) async -> String {
        let intent = intentParser.parse(text)

        guard let container = modelContainer else {
            return "I'm having trouble accessing your data. Please try again."
        }

        let context = container.mainContext

        switch intent {
        case .spendingQuery(let category, let merchant, let period):
            return await handleSpendingQuery(category: category, merchant: merchant, period: period, context: context)

        case .budgetStatus(let category):
            return await handleBudgetStatus(category: category, context: context)

        case .accountBalance(let accountName):
            return await handleBalanceQuery(accountName: accountName, context: context)

        case .transactionSearch(let merchant, _, _):
            return await handleTransactionSearch(merchant: merchant, context: context)

        case .generalAdvice(let topic):
            return handleAdvice(topic: topic)

        case .greeting:
            return "Hey there! How can I help with your finances today? You can ask about spending, budgets, account balances, or search for specific transactions."

        case .unknown:
            return "I can help with spending questions, budget tracking, account balances, and transaction searches. Try asking something like \"How much did I spend on food this month?\" or \"What's my balance?\""
        }
    }

    private func handleSpendingQuery(category: String?, merchant: String?, period: DatePeriod, context: ModelContext) async -> String {
        let range = period.dateRange
        let descriptor = FetchDescriptor<SDTransaction>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        guard let allTxns = try? context.fetch(descriptor) else {
            return "I couldn't access your transactions. Please try again."
        }

        let categories = (try? context.fetch(FetchDescriptor<SDCategory>())) ?? []

        var filtered = allTxns.filter { $0.date >= range.start && $0.date <= range.end && $0.amount > 0 }

        var label = "spending"

        if let merchant {
            let lowered = merchant.lowercased()
            filtered = filtered.filter { ($0.merchantName ?? "").lowercased().contains(lowered) }
            label = merchant
        } else if let category {
            let matchedCat = categories.first { $0.name.localizedCaseInsensitiveContains(category) }
            if let catId = matchedCat?.id {
                filtered = filtered.filter { $0.categoryId == catId }
                label = matchedCat?.name ?? category
            }
        }

        let total = filtered.reduce(Decimal.zero) { $0 + $1.amount }
        let count = filtered.count

        let periodLabel: String = switch period {
        case .today: "today"
        case .thisWeek: "this week"
        case .thisMonth: "this month"
        case .lastMonth: "last month"
        case .last30Days: "the last 30 days"
        case .last90Days: "the last 90 days"
        case .custom: "that period"
        }

        if count == 0 {
            return "I don't see any \(label) transactions \(periodLabel)."
        }

        var response = "You spent **\(total.currencyFormatted)** on \(label) \(periodLabel) across **\(count) transaction\(count == 1 ? "" : "s")**."

        // Top merchants
        var merchantTotals: [String: Decimal] = [:]
        for txn in filtered {
            let name = txn.merchantName ?? "Unknown"
            merchantTotals[name, default: 0] += txn.amount
        }
        let topMerchants = merchantTotals.sorted { $0.value > $1.value }.prefix(3)
        if topMerchants.count > 1 {
            response += "\n\nTop merchants:"
            for (name, amount) in topMerchants {
                response += "\n- \(name): \(amount.currencyFormatted)"
            }
        }

        return response
    }

    private func handleBudgetStatus(category: String?, context: ModelContext) async -> String {
        let budgets = (try? context.fetch(FetchDescriptor<SDBudget>())) ?? []
        let monthStart = Date().startOfMonth
        guard let budget = budgets.first(where: { Calendar.current.isDate($0.month, equalTo: monthStart, toGranularity: .month) }) else {
            return "You don't have a budget set up for this month yet."
        }

        let categories = (try? context.fetch(FetchDescriptor<SDCategory>())) ?? []
        let allTxns = (try? context.fetch(FetchDescriptor<SDTransaction>())) ?? []

        func spent(for categoryId: UUID) -> Decimal {
            allTxns.filter { $0.categoryId == categoryId && $0.date >= monthStart && $0.amount > 0 }
                .reduce(Decimal.zero) { $0 + $1.amount }
        }

        if let category {
            let matchedCat = categories.first { $0.name.localizedCaseInsensitiveContains(category) }
            if let catId = matchedCat?.id, let line = budget.lines.first(where: { $0.categoryId == catId }) {
                let s = spent(for: catId)
                let pct = line.allocatedAmount > 0 ? Int(Double(truncating: (s / line.allocatedAmount) as NSDecimalNumber) * 100) : 0
                let remaining = line.allocatedAmount - s
                return "**\(matchedCat!.name)** budget: \(s.currencyFormatted) spent of \(line.allocatedAmount.currencyFormatted) (\(pct)%).\n\nYou have \(remaining.currencyFormatted) remaining this month."
            }
            return "I couldn't find a budget category matching \"\(category)\"."
        }

        let totalAllocated = budget.lines.reduce(Decimal.zero) { $0 + $1.allocatedAmount }
        let totalSpent = budget.lines.reduce(Decimal.zero) { $0 + spent(for: $1.categoryId) }
        let pct = totalAllocated > 0 ? Int(Double(truncating: (totalSpent / totalAllocated) as NSDecimalNumber) * 100) : 0

        var response = "**Monthly Budget Overview**\n\nSpent: \(totalSpent.currencyFormatted) of \(totalAllocated.currencyFormatted) (\(pct)%)\n"

        let overBudget = budget.lines.filter { spent(for: $0.categoryId) > $0.allocatedAmount }
        let nearLimit = budget.lines.filter {
            let s = spent(for: $0.categoryId)
            let p = $0.allocatedAmount > 0 ? Double(truncating: (s / $0.allocatedAmount) as NSDecimalNumber) : 0
            return p >= 0.8 && s <= $0.allocatedAmount
        }

        if !overBudget.isEmpty {
            response += "\nOver budget:"
            for line in overBudget {
                let name = categories.first { $0.id == line.categoryId }?.name ?? "Unknown"
                let s = spent(for: line.categoryId)
                response += "\n- \(name): \(s.currencyFormatted) / \(line.allocatedAmount.currencyFormatted)"
            }
        }

        if !nearLimit.isEmpty {
            response += "\n\nApproaching limit:"
            for line in nearLimit {
                let name = categories.first { $0.id == line.categoryId }?.name ?? "Unknown"
                let s = spent(for: line.categoryId)
                let p = Int(Double(truncating: (s / line.allocatedAmount) as NSDecimalNumber) * 100)
                response += "\n- \(name): \(p)% used"
            }
        }

        return response
    }

    private func handleBalanceQuery(accountName: String?, context: ModelContext) async -> String {
        let accounts = (try? context.fetch(FetchDescriptor<SDAccount>())) ?? []

        if accounts.isEmpty {
            return "You don't have any accounts linked yet. Connect a bank account to see your balances."
        }

        if let name = accountName {
            let lowered = name.lowercased()
            if let account = accounts.first(where: { $0.accountName.lowercased().contains(lowered) || $0.institutionName.lowercased().contains(lowered) }) {
                return "**\(account.accountName)** (\(account.institutionName)): \(account.currentBalance.currencyFormatted)"
            }
            return "I couldn't find an account matching \"\(name)\". Your accounts: \(accounts.map { $0.accountName }.joined(separator: ", "))."
        }

        let total = accounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
        var response = "**Total across all accounts: \(total.currencyFormatted)**\n"
        for account in accounts {
            response += "\n- \(account.accountName) (\(account.institutionName)): \(account.currentBalance.currencyFormatted)"
        }
        return response
    }

    private func handleTransactionSearch(merchant: String?, context: ModelContext) async -> String {
        guard let merchant else {
            return "What merchant or transaction would you like me to search for?"
        }

        let allTxns = (try? context.fetch(FetchDescriptor<SDTransaction>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let lowered = merchant.lowercased()
        let matched = allTxns.filter { ($0.merchantName ?? $0.originalDescription).lowercased().contains(lowered) }

        if matched.isEmpty {
            return "I didn't find any transactions from \"\(merchant)\"."
        }

        let total = matched.filter { $0.amount > 0 }.reduce(Decimal.zero) { $0 + $1.amount }
        var response = "Found **\(matched.count)** transaction\(matched.count == 1 ? "" : "s") from \(merchant) (total: \(total.currencyFormatted)).\n\nRecent:"

        for txn in matched.prefix(5) {
            let date = txn.date.formatted(date: .abbreviated, time: .omitted)
            let amt = txn.amount < 0 ? "+\((-txn.amount).currencyFormatted)" : txn.amount.currencyFormatted
            response += "\n- \(date): \(amt)"
        }

        if matched.count > 5 {
            response += "\n\n...and \(matched.count - 5) more."
        }

        return response
    }

    private func handleAdvice(topic: String) -> String {
        "I'm here to help you understand your spending and stay on budget. While I can't give specific investment advice, I can help you:\n\n- Track where your money goes\n- Stay within your budget\n- Spot unusual spending patterns\n- Find subscriptions you might want to cancel\n\nWhat would you like to explore?"
    }
}

private extension Decimal {
    var currencyFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: self as NSDecimalNumber) ?? "$0.00"
    }
}
