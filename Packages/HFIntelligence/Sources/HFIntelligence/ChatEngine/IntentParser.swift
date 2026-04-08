import Foundation
import HFDomain

public struct IntentParser: Sendable {
    public init() {}

    public func parse(_ query: String) -> ChatIntent {
        let lowered = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if isGreeting(lowered) {
            return .greeting
        }

        if let intent = parseTrendQuery(lowered) {
            return intent
        }

        if let intent = parseAnomalyQuery(lowered) {
            return intent
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

    // MARK: - Trend Query

    private func parseTrendQuery(_ text: String) -> ChatIntent? {
        let patterns = [
            #"(?:spending )?trend(?:s)?(?: for| on| of)?\s*(.+?)(?:\s+(?:over|for|in)\s+(?:the\s+)?(?:last\s+)?(\d+)\s+months?)?"#,
            #"how (?:has|have) (?:my )?(.+?) (?:spending )?(?:changed|trended|evolved)"#,
            #"(.+?) spending (?:over|for|in) (?:the )?(?:last )?(\d+) months?"#,
            #"show (?:me )?(?:my )?(.+?) (?:spending )?(?:over|for) (?:the )?(?:last )?(\d+) months?"#,
        ]

        for pattern in patterns {
            if let match = text.firstMatch(of: try! Regex(pattern)) {
                let subject = match.output.count > 1 ? match.output[1].substring.map(String.init) : nil
                let monthsStr = match.output.count > 2 ? match.output[2].substring.map(String.init) : nil
                let months = monthsStr.flatMap(Int.init) ?? 3
                let (category, _) = classifySubject(subject)
                return .trendQuery(category: category ?? subject, months: months)
            }
        }
        return nil
    }

    // MARK: - Anomaly Query

    private func parseAnomalyQuery(_ text: String) -> ChatIntent? {
        let patterns = [
            #"(?:anything|something) unusual"#,
            #"(?:any )?(?:spending )?spikes?"#,
            #"(?:did i|have i) (?:spend|spent) more than usual"#,
            #"unusual (?:spending|transactions?|charges?)"#,
            #"(?:more|higher|greater) than (?:usual|normal|average)(?: (?:on|for|in) (.+))?"#,
            #"(?:is|was) (?:my )?(.+?) (?:spending )?(?:unusually |abnormally )?(?:high|higher|elevated)"#,
        ]

        for pattern in patterns {
            if let match = text.firstMatch(of: try! Regex(pattern)) {
                let subject = match.output.count > 1 ? match.output[1].substring.map(String.init) : nil
                let (category, _) = classifySubject(subject)
                return .anomalyCheck(category: category ?? subject, period: .thisMonth)
            }
        }
        return nil
    }

    // MARK: - Spending Query

    private func parseSpendingQuery(_ text: String, raw: String) -> ChatIntent? {
        let spendingPatterns = [
            #"how much (?:did i|have i|i) (?:spend|spent) (?:on|at|for) (.+?)(?:\s+(?:this|last|in|over)\s+(.+))?$"#,
            #"(?:total|sum|amount) (?:spent|spending|expenses?|costs?) (?:on|at|for|in) (.+?)(?:\s+(?:this|last|in|over)\s+(.+))?$"#,
            #"(?:total|all|my) (.+?) (?:spending|expenses?|costs?)(?: (?:this|last|in|over|for)\s+(.+))?$"#,
            #"(.+?) (?:spending|expenses?|costs?)(?: (?:this|last|in|over|for)\s+(.+))?$"#,
            #"what (?:did i|have i) (?:spend|spent) (?:on|at) (.+)"#,
            #"how much (?:on|for|in) (.+?)(?:\s+(?:this|last|in|over)\s+(.+))?$"#,
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

    // MARK: - Budget Query

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

    // MARK: - Balance Query

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

    // MARK: - Transaction Search

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

    // MARK: - Advice Query

    private func parseAdviceQuery(_ text: String) -> ChatIntent? {
        let adviceKeywords = ["how can i save", "tips for", "advice on", "help me with", "suggest", "recommend", "should i"]
        for keyword in adviceKeywords {
            if text.contains(keyword) {
                return .generalAdvice(topic: text)
            }
        }
        return nil
    }

    // MARK: - Period Parsing

    private func parsePeriod(_ text: String?) -> DatePeriod? {
        guard let raw = text?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // Strip leading "the" for patterns like "the last 2 months"
        let text = raw.hasPrefix("the ") ? String(raw.dropFirst(4)) : raw

        if text.contains("today") { return .today }
        if text.contains("this week") { return .thisWeek }
        if text.contains("this month") { return .thisMonth }
        if text == "last month" || text.hasPrefix("last month") { return .lastMonth }
        if text.contains("30 days") { return .last30Days }
        if text.contains("90 days") { return .last90Days }

        // "last N months" / "N months"
        let nMonthsPattern = /(?:last\s+)?(\d+)\s+months?/
        if let match = text.firstMatch(of: nMonthsPattern) {
            if let n = Int(match.1) {
                return .lastNMonths(n)
            }
        }

        if text.contains("3 months") { return .last90Days }

        return nil
    }

    // MARK: - Subject Classification

    private func classifySubject(_ subject: String?) -> (category: String?, merchant: String?) {
        guard let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (nil, nil)
        }

        let categoryNames = SpendingCategory.systemCategories.map { $0.name.lowercased() }
        let categoryKeywords: [String: String] = [
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
