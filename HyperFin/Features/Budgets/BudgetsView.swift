import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

struct BudgetsView: View {
    @Query private var budgets: [SDBudget]
    @Query(sort: \SDCategory.name) private var categories: [SDCategory]
    @Query private var allTransactions: [SDTransaction]

    private var currentBudget: SDBudget? {
        let start = Date().startOfMonth
        return budgets.first { Calendar.current.isDate($0.month, equalTo: start, toGranularity: .month) }
    }

    private var monthStart: Date { Date().startOfMonth }

    private func spent(for categoryId: UUID) -> Decimal {
        allTransactions
            .filter { $0.categoryId == categoryId && $0.date >= monthStart && $0.amount > 0 }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let budget = currentBudget {
                    budgetList(budget)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Budgets")
        }
    }

    private func budgetList(_ budget: SDBudget) -> some View {
        List {
            let totalAllocated = budget.lines.reduce(Decimal.zero) { $0 + $1.allocatedAmount }
            let totalSpent = budget.lines.reduce(Decimal.zero) { $0 + spent(for: $1.categoryId) }

            Section {
                VStack(spacing: 8) {
                    Text("April 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text(totalSpent.currencyFormatted)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("of \(totalAllocated.currencyFormatted)")
                            .foregroundStyle(.secondary)
                    }
                    let pct = totalAllocated > 0
                        ? min(Double(truncating: (totalSpent / totalAllocated) as NSDecimalNumber), 1.0)
                        : 0.0
                    ProgressView(value: pct)
                        .tint(pct > 0.8 ? .red : .blue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Categories") {
                ForEach(budget.lines.sorted(by: { spent(for: $0.categoryId) > spent(for: $1.categoryId) })) { line in
                    let catName = categories.first { $0.id == line.categoryId }?.name ?? "Unknown"
                    let catIcon = categories.first { $0.id == line.categoryId }?.icon ?? "circle"
                    let lineSpent = spent(for: line.categoryId)
                    let pct = line.allocatedAmount > 0
                        ? Double(truncating: (lineSpent / line.allocatedAmount) as NSDecimalNumber)
                        : 0.0

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: catIcon)
                                .foregroundStyle(.blue)
                                .frame(width: 20)
                            Text(catName)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(lineSpent.currencyFormatted)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(pct > 1.0 ? .red : .primary)
                            Text("/ \(line.allocatedAmount.currencyFormatted)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(pct, 1.0))
                            .tint(pct > 1.0 ? .red : pct > 0.8 ? .orange : .green)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 60))
                .foregroundStyle(.blue.opacity(0.6))
            Text("No Budget Yet")
                .font(.title2.bold())
            Text("Connect your bank accounts and HyperFin will analyze your spending to suggest a personalized budget.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}
