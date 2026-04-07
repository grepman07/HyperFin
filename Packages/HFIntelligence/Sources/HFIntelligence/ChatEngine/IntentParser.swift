import Foundation
import HFDomain

public struct IntentParser: Sendable {
    public init() {}

    public func parse(_ query: String) -> ChatIntent {
        let lowered = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if isGreeting(lowered) {
            return .greeting
        }

        if let intent = parseSpendingQuery(lowered, raw: query) {
            return intent
        }

        if let intent = parseBudgetQuery(lowered) {
            return intent
        }

        if let intent = parseBalanceQuery(lowered) {
            return intent
        }

        if let intent = parseTransactionSearch(lowered) {
            return intent
        }

        if let intent = parseAdviceQuery(lowered) {
            return intent
        }

        return .unknown(rawQuery: query)
    }

    private func isGreeting(_ text: String) -> Bool {
        let greetings = ["hello", "hi", "hey", "good morning", "good afternoon", "good evening", "what's up", "howdy"]
        return greetings.contains(where: { text.hasPrefix($0) }) && text.count < 30
    }

    private func parseSpendingQuery(_ text: String, raw: String) -> ChatIntent? {
        let spendingPatterns = [
            #"how much (?:did i|have i|i) (?:spend|spent) (?:on|at|for) (.+?)(?:\s+(?:this|last|in)\s+(.+))?$"#,
            #"(?:total|sum|amount) (?:spent|spending) (?:on|at|for) (.+?)(?:\s+(?:this|last|in)\s+(.+))?$"#,
            #"(.+?) spending(?: (?:this|last|in)\s+(.+))?$"#,
            #"what (?:did i|have i) (?:spend|spent) (?:on|at) (.+)"#,
        ]

        for pattern in spendingPatterns {
            if let match = text.firstMatch(of: try! Regex(pattern)) {
                let subject = match.output.count > 1 ? String(match.output[1].substring ?? "") : nil
                let periodStr = match.output.count > 2 ? match.output[2].substring.map(String.init) : nil
                let period = parsePeriod(periodStr) ?? .thisMonth

                let (category, merchant) = classifySubject(subject)
                return .spendingQuery(category: category, merchant: merchant, period: period)
            }
        }

        return nil
    }

    private func parseBudgetQuery(_ text: String) -> ChatIntent? {
        let patterns = [
            #"(?:budget|budgeting)(?: status| for| of)?\s*(.+)?"#,
            #"am i (?:over|under|within) budget"#,
            #"how (?:am i|is my) (?:doing|budget)"#,
        ]

        for pattern in patterns {
            if let match = text.firstMatch(of: try! Regex(pattern)) {
                let category = match.output.count > 1 ? match.output[1].substring.map(String.init) : nil
                return .budgetStatus(category: category)
            }
        }

        return nil
    }

    private func parseBalanceQuery(_ text: String) -> ChatIntent? {
        let patterns = [
            #"(?:what(?:'s| is) my|show|check|how much (?:do i have|is) in) (?:(?:(.+?) )?balance|(?:(.+?) )?account)"#,
            #"(?:total )?balance"#,
        ]

        for pattern in patterns {
            if let match = text.firstMatch(of: try! Regex(pattern)) {
                let account = (1..<match.output.count).compactMap { match.output[$0].substring.map(String.init) }.first
                return .accountBalance(accountName: account)
            }
        }

        return nil
    }

    private func parseTransactionSearch(_ text: String) -> ChatIntent? {
        let patterns = [
            #"(?:find|search|show|list) (?:transactions?|charges?|payments?) (?:from|at|for) (.+)"#,
            #"(?:recent|latest|last) (?:transactions?|charges?|payments?)(?: (?:from|at|for) (.+))?"#,
        ]

        for pattern in patterns {
            if let match = text.firstMatch(of: try! Regex(pattern)) {
                let merchant = match.output.count > 1 ? match.output[1].substring.map(String.init) : nil
                return .transactionSearch(merchant: merchant, minAmount: nil, maxAmount: nil)
            }
        }

        return nil
    }

    private func parseAdviceQuery(_ text: String) -> ChatIntent? {
        let adviceKeywords = ["how can i save", "tips for", "advice on", "help me with", "suggest", "recommend", "should i"]
        for keyword in adviceKeywords {
            if text.contains(keyword) {
                return .generalAdvice(topic: text)
            }
        }
        return nil
    }

    private func parsePeriod(_ text: String?) -> DatePeriod? {
        guard let text = text?.lowercased() else { return nil }
        if text.contains("today") { return .today }
        if text.contains("this week") { return .thisWeek }
        if text.contains("this month") { return .thisMonth }
        if text.contains("last month") { return .lastMonth }
        if text.contains("30 days") { return .last30Days }
        if text.contains("90 days") || text.contains("3 months") { return .last90Days }
        return nil
    }

    private func classifySubject(_ subject: String?) -> (category: String?, merchant: String?) {
        guard let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (nil, nil)
        }

        let categoryNames = SpendingCategory.systemCategories.map { $0.name.lowercased() }
        let categoryKeywords = [
            "food": "Food & Dining", "dining": "Food & Dining", "restaurants": "Food & Dining",
            "transport": "Transportation", "gas": "Transportation", "uber": "Transportation", "lyft": "Transportation",
            "shopping": "Shopping", "clothes": "Shopping",
            "entertainment": "Entertainment", "movies": "Entertainment",
            "groceries": "Groceries", "grocery": "Groceries",
            "bills": "Bills & Utilities", "utilities": "Bills & Utilities",
            "subscriptions": "Subscriptions",
            "health": "Health & Fitness", "gym": "Health & Fitness",
            "travel": "Travel",
        ]

        let lowered = subject.lowercased()
        if categoryNames.contains(lowered) {
            return (subject, nil)
        }
        if let mapped = categoryKeywords[lowered] {
            return (mapped, nil)
        }

        return (nil, subject)
    }
}
