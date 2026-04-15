import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

/// Three sections (credit / mortgage / student) rendered from the stored
/// JSON payload per liability row. Shows only the fields the user is likely
/// to glance at — balances, rates, and next payment. Everything else the
/// server stored is available for deeper views later.
struct LiabilitiesListView: View {
    @Query private var rows: [SDLiability]

    private var credit: [CreditLiability] {
        rows.filter { $0.kind == "credit" }
            .compactMap { $0.toLiability() }
            .compactMap { if case let .credit(c) = $0 { return c } else { return nil } }
    }

    private var mortgages: [MortgageLiability] {
        rows.filter { $0.kind == "mortgage" }
            .compactMap { $0.toLiability() }
            .compactMap { if case let .mortgage(m) = $0 { return m } else { return nil } }
    }

    private var students: [StudentLiability] {
        rows.filter { $0.kind == "student" }
            .compactMap { $0.toLiability() }
            .compactMap { if case let .student(s) = $0 { return s } else { return nil } }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                emptyState
            } else {
                if !credit.isEmpty {
                    Section("Credit Cards") {
                        ForEach(credit, id: \.accountId) { creditRow($0) }
                    }
                }
                if !mortgages.isEmpty {
                    Section("Mortgages") {
                        ForEach(mortgages, id: \.accountId) { mortgageRow($0) }
                    }
                }
                if !students.isEmpty {
                    Section("Student Loans") {
                        ForEach(students, id: \.accountId) { studentRow($0) }
                    }
                }
            }
        }
        .navigationTitle("Liabilities")
    }

    @ViewBuilder
    private func creditRow(_ c: CreditLiability) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let bal = c.lastStatementBalance {
                    Text(bal, format: .currency(code: "USD"))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
            if let apr = c.purchaseAPR {
                HStack {
                    Text("Purchase APR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(apr, specifier: "%.2f")%")
                        .font(.caption.monospacedDigit())
                }
            }
            if let due = c.nextPaymentDueDate, let min = c.minimumPaymentAmount {
                HStack {
                    Text("Due \(due)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("min ") + Text(min, format: .currency(code: "USD"))
                }
                .font(.caption.monospacedDigit())
            }
            if c.isOverdue == true {
                Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func mortgageRow(_ m: MortgageLiability) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let rate = m.interestRatePercentage {
                HStack {
                    Text("Rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(rate, specifier: "%.3f")% \(m.interestRateType ?? "")")
                        .font(.caption.monospacedDigit())
                }
            }
            if let next = m.nextMonthlyPayment, let date = m.nextPaymentDueDate {
                HStack {
                    Text("Next \(date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(next, format: .currency(code: "USD"))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
            }
            if let ytdI = m.ytdInterestPaid, let ytdP = m.ytdPrincipalPaid {
                HStack {
                    Text("YTD interest / principal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ytdI, format: .currency(code: "USD")) + Text(" / ") + Text(ytdP, format: .currency(code: "USD"))
                }
                .font(.caption.monospacedDigit())
            }
            if let past = m.pastDueAmount, past > 0 {
                Label {
                    Text("Past due ") + Text(past, format: .currency(code: "USD"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func studentRow(_ s: StudentLiability) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = s.loanName {
                Text(name)
                    .font(.subheadline.weight(.semibold))
            }
            if let rate = s.interestRatePercentage {
                HStack {
                    Text("Rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(rate, specifier: "%.3f")%")
                        .font(.caption.monospacedDigit())
                }
            }
            if let min = s.minimumPaymentAmount, let due = s.nextPaymentDueDate {
                HStack {
                    Text("Due \(due)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(min, format: .currency(code: "USD"))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
            }
            if let payoff = s.expectedPayoffDate {
                HStack {
                    Text("Expected payoff")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(payoff)
                        .font(.caption)
                }
            }
            if let status = s.loanStatusType {
                Text("Status: \(status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue.opacity(0.6))
                Text("No Liabilities")
                    .font(.headline)
                Text("Credit cards, mortgages, and student loans from your linked institutions will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}
