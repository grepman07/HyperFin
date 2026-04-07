import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

struct DashboardView: View {
    @Query(sort: \SDAccount.institutionName) private var accounts: [SDAccount]
    @Query(sort: \SDTransaction.date, order: .reverse) private var allTransactions: [SDTransaction]
    @Query private var budgets: [SDBudget]

    private var totalBalance: Decimal {
        accounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }

    private var monthlyTransactions: [SDTransaction] {
        let start = Date().startOfMonth
        return allTransactions.filter { $0.date >= start && $0.amount > 0 }
    }

    private var monthlySpending: Decimal {
        monthlyTransactions.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var currentBudget: SDBudget? {
        let start = Date().startOfMonth
        return budgets.first { Calendar.current.isDate($0.month, equalTo: start, toGranularity: .month) }
    }

    private var totalBudgeted: Decimal {
        currentBudget?.lines.reduce(Decimal.zero) { $0 + $1.allocatedAmount } ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    balanceCard
                    monthSummaryCard
                    recentTransactionsCard
                }
                .padding()
            }
            .navigationTitle("Dashboard")
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 8) {
            Text("Total Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(totalBalance.currencyFormatted)
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s") linked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var monthSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This Month")
                .font(.headline)

            HStack {
                VStack(alignment: .leading) {
                    Text("Spent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(monthlySpending.currencyFormatted)
                        .font(.title2.bold())
                        .foregroundStyle(.red)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Budget")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(totalBudgeted.currencyFormatted)
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                }
            }

            if totalBudgeted > 0 {
                let pct = min(Double(truncating: (monthlySpending / totalBudgeted) as NSDecimalNumber), 1.0)
                ProgressView(value: pct)
                    .tint(pct > 0.8 ? .red : .blue)
                Text("\(Int(pct * 100))% of budget used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var recentTransactionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Transactions")
                    .font(.headline)
                Spacer()
                NavigationLink("See All") {
                    TransactionsView()
                }
                .font(.subheadline)
            }

            ForEach(allTransactions.prefix(8)) { txn in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(txn.merchantName ?? txn.originalDescription)
                            .font(.subheadline)
                        Text(txn.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(txn.amount < 0 ? "+\(abs(txn.amount).currencyFormatted)" : txn.amount.currencyFormatted)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(txn.amount < 0 ? .green : .primary)
                }
                if txn.id != allTransactions.prefix(8).last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

extension Decimal {
    fileprivate func abs() -> Decimal {
        self < 0 ? -self : self
    }
}

private func abs(_ d: Decimal) -> Decimal {
    d < 0 ? -d : d
}
