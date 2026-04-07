import Foundation
import HFDomain

struct CategorizationRule {
    let keywords: [String]
    let categoryName: String
}

public struct CategorizationRuleEngine: Sendable {
    private let rules: [CategorizationRule]
    private let categoryIdMap: [String: UUID]

    public init() {
        let categories = SpendingCategory.systemCategories
        self.categoryIdMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0.id) })

        self.rules = [
            CategorizationRule(keywords: ["uber", "lyft", "taxi", "metro", "subway", "parking", "gas station", "shell", "chevron", "exxon", "bp"], categoryName: "Transportation"),
            CategorizationRule(keywords: ["mcdonald", "starbucks", "chipotle", "doordash", "grubhub", "uber eats", "restaurant", "pizza", "sushi", "cafe", "diner", "bar & grill"], categoryName: "Food & Dining"),
            CategorizationRule(keywords: ["walmart grocery", "trader joe", "whole foods", "kroger", "safeway", "aldi", "costco", "target grocery", "publix", "heb"], categoryName: "Groceries"),
            CategorizationRule(keywords: ["amazon", "walmart", "target", "best buy", "apple store", "nike", "zara", "h&m", "nordstrom", "macys"], categoryName: "Shopping"),
            CategorizationRule(keywords: ["netflix", "spotify", "hulu", "disney+", "hbo", "youtube", "apple tv", "paramount", "peacock", "audible"], categoryName: "Subscriptions"),
            CategorizationRule(keywords: ["electric", "water", "internet", "comcast", "verizon", "at&t", "t-mobile", "pge", "con edison", "xfinity"], categoryName: "Bills & Utilities"),
            CategorizationRule(keywords: ["movie", "cinema", "theater", "concert", "bowling", "arcade", "amusement", "museum", "zoo", "ticketmaster"], categoryName: "Entertainment"),
            CategorizationRule(keywords: ["gym", "fitness", "planet fitness", "equinox", "pharmacy", "cvs", "walgreens", "doctor", "dental", "hospital"], categoryName: "Health & Fitness"),
            CategorizationRule(keywords: ["hotel", "airbnb", "airline", "united", "delta", "american airlines", "southwest", "expedia", "booking.com"], categoryName: "Travel"),
            CategorizationRule(keywords: ["rent", "mortgage", "home depot", "lowes", "ikea", "furniture", "plumber", "cleaning"], categoryName: "Home"),
            CategorizationRule(keywords: ["salon", "barber", "spa", "nails", "beauty", "sephora", "ulta"], categoryName: "Personal Care"),
            CategorizationRule(keywords: ["tuition", "school", "university", "udemy", "coursera", "textbook"], categoryName: "Education"),
            CategorizationRule(keywords: ["payroll", "direct deposit", "salary", "wage", "income", "bonus", "dividend"], categoryName: "Income"),
            CategorizationRule(keywords: ["transfer", "zelle", "venmo", "paypal", "cash app", "wire"], categoryName: "Transfer"),
        ]
    }

    public func categorize(description: String) -> UUID? {
        let lowered = description.lowercased()
        for rule in rules {
            if rule.keywords.contains(where: { lowered.contains($0) }) {
                return categoryIdMap[rule.categoryName]
            }
        }
        return nil
    }
}
