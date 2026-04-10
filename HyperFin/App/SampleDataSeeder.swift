import Foundation
import SwiftData
import HFDomain
import HFData
import HFShared

@MainActor
struct SampleDataSeeder {
    let container: ModelContainer

    func seedIfNeeded() async {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDAccount>()
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        guard existing == 0 else { return }

        HFLogger.data.info("Seeding sample data for testing...")

        // Seed categories first
        let categories = SpendingCategory.systemCategories
        var categoryMap: [String: UUID] = [:]
        for cat in categories {
            context.insert(SDCategory(from: cat))
            categoryMap[cat.name] = cat.id
        }

        // Create sample accounts
        let checking = Account(
            plaidAccountId: "sample_checking_001",
            institutionName: "Chase",
            accountName: "Total Checking",
            accountType: .checking,
            currentBalance: 4_287.53,
            availableBalance: 4_187.53,
            lastSynced: Date()
        )
        let savings = Account(
            plaidAccountId: "sample_savings_001",
            institutionName: "Chase",
            accountName: "Savings",
            accountType: .savings,
            currentBalance: 12_450.00,
            lastSynced: Date()
        )
        let credit = Account(
            plaidAccountId: "sample_credit_001",
            institutionName: "Amex",
            accountName: "Blue Cash Preferred",
            accountType: .credit,
            currentBalance: -1_823.47,
            lastSynced: Date()
        )

        context.insert(SDAccount(from: checking))
        context.insert(SDAccount(from: savings))
        context.insert(SDAccount(from: credit))

        // Generate realistic transactions for the past 60 days
        let transactions = generateTransactions(
            checkingId: checking.id,
            creditId: credit.id,
            categoryMap: categoryMap
        )

        for txn in transactions {
            context.insert(SDTransaction(from: txn))
        }

        // Generate budget for current month
        let budget = generateBudget(categories: categories)
        let sdBudget = SDBudget(from: budget)
        context.insert(sdBudget)
        for line in budget.lines {
            let sdLine = SDBudgetLine(from: line)
            sdLine.budget = sdBudget
            context.insert(sdLine)
        }

        // Seed merchant mappings
        let mappings = generateMerchantMappings(categoryMap: categoryMap)
        for mapping in mappings {
            context.insert(SDMerchantMapping(from: mapping))
        }

        // Seed alert configs
        let alerts = [
            AlertConfig(alertType: .budgetThreshold, isEnabled: true, threshold: 0.80),
            AlertConfig(alertType: .budgetExceeded, isEnabled: true),
            AlertConfig(alertType: .unusualTransaction, isEnabled: true),
            AlertConfig(alertType: .weeklySummary, isEnabled: true, preferredDay: 1, preferredHour: 9),
        ]
        for alert in alerts {
            context.insert(SDAlertConfig(from: alert))
        }

        // Seed user profile
        let profile = UserProfile(
            monthlyIncome: 7_500,
            financialGoals: ["Build emergency fund", "Pay off credit card", "Save for vacation"],
            onboardingCompleted: true,
            preferredCurrency: "USD"
        )
        context.insert(SDUserProfile(from: profile))

        try? context.save()
        HFLogger.data.info("Sample data seeded: \(transactions.count) transactions, 3 accounts, 1 budget")
    }

    private func generateTransactions(checkingId: UUID, creditId: UUID, categoryMap: [String: UUID]) -> [Transaction] {
        var transactions: [Transaction] = []
        let calendar = Calendar.current

        struct TxnTemplate {
            let merchant: String
            let category: String
            let minAmount: Double
            let maxAmount: Double
            let frequency: Int // approx times per month
            let accountType: String // "checking" or "credit"
        }

        let templates: [TxnTemplate] = [
            // Food & Dining
            TxnTemplate(merchant: "Starbucks", category: "Food & Dining", minAmount: 4.50, maxAmount: 8.75, frequency: 12, accountType: "credit"),
            TxnTemplate(merchant: "Chipotle", category: "Food & Dining", minAmount: 10.50, maxAmount: 16.00, frequency: 6, accountType: "credit"),
            TxnTemplate(merchant: "DoorDash", category: "Food & Dining", minAmount: 18.00, maxAmount: 45.00, frequency: 4, accountType: "credit"),
            TxnTemplate(merchant: "Olive Garden", category: "Food & Dining", minAmount: 35.00, maxAmount: 85.00, frequency: 2, accountType: "credit"),
            TxnTemplate(merchant: "McDonald's", category: "Food & Dining", minAmount: 6.00, maxAmount: 14.00, frequency: 5, accountType: "credit"),
            TxnTemplate(merchant: "Sweetgreen", category: "Food & Dining", minAmount: 12.00, maxAmount: 18.00, frequency: 3, accountType: "credit"),
            // Groceries
            TxnTemplate(merchant: "Trader Joe's", category: "Groceries", minAmount: 45.00, maxAmount: 120.00, frequency: 4, accountType: "checking"),
            TxnTemplate(merchant: "Whole Foods", category: "Groceries", minAmount: 30.00, maxAmount: 90.00, frequency: 3, accountType: "credit"),
            TxnTemplate(merchant: "Costco", category: "Groceries", minAmount: 80.00, maxAmount: 250.00, frequency: 2, accountType: "checking"),
            // Transportation
            TxnTemplate(merchant: "Uber", category: "Transportation", minAmount: 8.00, maxAmount: 35.00, frequency: 6, accountType: "credit"),
            TxnTemplate(merchant: "Lyft", category: "Transportation", minAmount: 10.00, maxAmount: 28.00, frequency: 3, accountType: "credit"),
            TxnTemplate(merchant: "Shell Gas Station", category: "Transportation", minAmount: 35.00, maxAmount: 65.00, frequency: 3, accountType: "checking"),
            TxnTemplate(merchant: "MTA MetroCard", category: "Transportation", minAmount: 33.00, maxAmount: 33.00, frequency: 1, accountType: "checking"),
            // Shopping
            TxnTemplate(merchant: "Amazon", category: "Shopping", minAmount: 12.00, maxAmount: 150.00, frequency: 5, accountType: "credit"),
            TxnTemplate(merchant: "Target", category: "Shopping", minAmount: 20.00, maxAmount: 80.00, frequency: 2, accountType: "credit"),
            TxnTemplate(merchant: "Nike", category: "Shopping", minAmount: 45.00, maxAmount: 180.00, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "Apple Store", category: "Shopping", minAmount: 29.00, maxAmount: 199.00, frequency: 1, accountType: "credit"),
            // Subscriptions
            TxnTemplate(merchant: "Netflix", category: "Subscriptions", minAmount: 15.49, maxAmount: 15.49, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "Spotify", category: "Subscriptions", minAmount: 10.99, maxAmount: 10.99, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "Apple iCloud", category: "Subscriptions", minAmount: 2.99, maxAmount: 2.99, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "NYT Digital", category: "Subscriptions", minAmount: 4.25, maxAmount: 4.25, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "ChatGPT Plus", category: "Subscriptions", minAmount: 20.00, maxAmount: 20.00, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "YouTube Premium", category: "Subscriptions", minAmount: 13.99, maxAmount: 13.99, frequency: 1, accountType: "credit"),
            // Bills & Utilities
            TxnTemplate(merchant: "Verizon Wireless", category: "Bills & Utilities", minAmount: 85.00, maxAmount: 85.00, frequency: 1, accountType: "checking"),
            TxnTemplate(merchant: "Con Edison", category: "Bills & Utilities", minAmount: 95.00, maxAmount: 145.00, frequency: 1, accountType: "checking"),
            TxnTemplate(merchant: "Xfinity Internet", category: "Bills & Utilities", minAmount: 79.99, maxAmount: 79.99, frequency: 1, accountType: "checking"),
            // Entertainment
            TxnTemplate(merchant: "AMC Theatres", category: "Entertainment", minAmount: 15.00, maxAmount: 40.00, frequency: 2, accountType: "credit"),
            TxnTemplate(merchant: "Madison Square Garden", category: "Entertainment", minAmount: 75.00, maxAmount: 250.00, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "Steam Games", category: "Entertainment", minAmount: 9.99, maxAmount: 59.99, frequency: 1, accountType: "credit"),
            // Health & Fitness
            TxnTemplate(merchant: "Equinox", category: "Health & Fitness", minAmount: 110.00, maxAmount: 110.00, frequency: 1, accountType: "checking"),
            TxnTemplate(merchant: "CVS Pharmacy", category: "Health & Fitness", minAmount: 8.00, maxAmount: 45.00, frequency: 2, accountType: "credit"),
            TxnTemplate(merchant: "Walgreens", category: "Health & Fitness", minAmount: 5.00, maxAmount: 35.00, frequency: 1, accountType: "credit"),
            // Travel
            TxnTemplate(merchant: "Delta Airlines", category: "Travel", minAmount: 150.00, maxAmount: 450.00, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "Marriott Hotel", category: "Travel", minAmount: 120.00, maxAmount: 280.00, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "Airbnb", category: "Travel", minAmount: 85.00, maxAmount: 200.00, frequency: 1, accountType: "credit"),
            // Education
            TxnTemplate(merchant: "Udemy", category: "Education", minAmount: 12.99, maxAmount: 84.99, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "O'Reilly Books", category: "Education", minAmount: 29.99, maxAmount: 49.99, frequency: 1, accountType: "credit"),
            // Personal Care
            TxnTemplate(merchant: "Supercuts", category: "Personal Care", minAmount: 25.00, maxAmount: 45.00, frequency: 1, accountType: "credit"),
            TxnTemplate(merchant: "Sephora", category: "Personal Care", minAmount: 15.00, maxAmount: 65.00, frequency: 1, accountType: "credit"),
            // Home
            TxnTemplate(merchant: "Rent Payment", category: "Home", minAmount: 2_200.00, maxAmount: 2_200.00, frequency: 1, accountType: "checking"),
            TxnTemplate(merchant: "Home Depot", category: "Home", minAmount: 15.00, maxAmount: 120.00, frequency: 1, accountType: "credit"),
            // Income
            TxnTemplate(merchant: "Employer Direct Deposit", category: "Income", minAmount: -3_750.00, maxAmount: -3_750.00, frequency: 2, accountType: "checking"),
            TxnTemplate(merchant: "Venmo Transfer In", category: "Income", minAmount: -150.00, maxAmount: -25.00, frequency: 2, accountType: "checking"),
        ]

        for daysAgo in 0..<90 {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
            for template in templates {
                let dailyChance = Double(template.frequency) / 30.0
                guard Double.random(in: 0...1) < dailyChance else { continue }

                let amount: Decimal
                if template.minAmount == template.maxAmount {
                    amount = Decimal(template.minAmount)
                } else {
                    // Defensive: normalize so any accidentally-swapped
                    // min/max (as happened with Venmo Transfer In) still
                    // yields a valid ClosedRange instead of crashing.
                    let lo = Swift.min(template.minAmount, template.maxAmount)
                    let hi = Swift.max(template.minAmount, template.maxAmount)
                    let raw = Double.random(in: lo...hi)
                    amount = Decimal(string: String(format: "%.2f", raw))!
                }

                let accountId = template.accountType == "checking" ? checkingId : creditId
                let categoryId = categoryMap[template.category]

                transactions.append(Transaction(
                    plaidTransactionId: "sample_\(UUID().uuidString.prefix(8))",
                    accountId: accountId,
                    amount: amount,
                    date: date,
                    merchantName: template.merchant,
                    originalDescription: template.merchant,
                    categoryId: categoryId,
                    isUserCategorized: false
                ))
            }
        }

        return transactions
    }

    private func generateBudget(categories: [SpendingCategory]) -> Budget {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: Date())!.start

        let budgetAmounts: [String: Decimal] = [
            "Food & Dining": 600,
            "Groceries": 500,
            "Transportation": 350,
            "Shopping": 300,
            "Subscriptions": 50,
            "Bills & Utilities": 350,
            "Entertainment": 150,
            "Health & Fitness": 150,
            "Home": 2_200,
            "Personal Care": 75,
            "Travel": 200,
            "Education": 50,
        ]

        let lines = categories.compactMap { cat -> BudgetLine? in
            guard let amount = budgetAmounts[cat.name] else { return nil }
            return BudgetLine(categoryId: cat.id, allocatedAmount: amount, spentAmount: 0)
        }

        return Budget(
            month: monthStart,
            lines: lines,
            isAutoGenerated: true,
            isAccepted: true
        )
    }

    private func generateMerchantMappings(categoryMap: [String: UUID]) -> [MerchantMapping] {
        let mappings: [(String, String)] = [
            ("starbucks", "Food & Dining"), ("chipotle", "Food & Dining"), ("doordash", "Food & Dining"),
            ("mcdonald's", "Food & Dining"), ("sweetgreen", "Food & Dining"), ("olive garden", "Food & Dining"),
            ("trader joe's", "Groceries"), ("whole foods", "Groceries"), ("costco", "Groceries"),
            ("uber", "Transportation"), ("lyft", "Transportation"), ("shell", "Transportation"), ("mta", "Transportation"),
            ("amazon", "Shopping"), ("target", "Shopping"), ("nike", "Shopping"), ("apple store", "Shopping"),
            ("netflix", "Subscriptions"), ("spotify", "Subscriptions"), ("chatgpt", "Subscriptions"), ("youtube", "Subscriptions"),
            ("verizon", "Bills & Utilities"), ("con edison", "Bills & Utilities"), ("xfinity", "Bills & Utilities"),
            ("equinox", "Health & Fitness"), ("cvs", "Health & Fitness"), ("walgreens", "Health & Fitness"),
            ("amc", "Entertainment"), ("madison square", "Entertainment"), ("steam", "Entertainment"),
            ("delta", "Travel"), ("marriott", "Travel"), ("airbnb", "Travel"),
            ("udemy", "Education"), ("o'reilly", "Education"),
            ("supercuts", "Personal Care"), ("sephora", "Personal Care"),
            ("home depot", "Home"),
        ]

        return mappings.compactMap { (merchant, category) in
            guard let catId = categoryMap[category] else { return nil }
            return MerchantMapping(
                merchantName: merchant,
                categoryId: catId,
                confidence: 1.0,
                source: .rule
            )
        }
    }
}
