import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

/// Shows investment transactions (buys, sells, dividends, fees) grouped by
/// date. Amount is signed the Plaid way — positive means cash out of the
/// account (buy/fee), negative means cash in (dividend/sell proceeds).
struct InvestmentTransactionsListView: View {
    @Query(sort: \SDInvestmentTransaction.date, order: .reverse)
    private var transactions: [SDInvestmentTransaction]

    @Query private var securities: [SDSecurity]

    private var securitiesById: [String: SDSecurity] {
        Dictionary(uniqueKeysWithValues: securities.map { ($0.securityId, $0) })
    }

    private var transactionsByDate: [(date: Date, items: [SDInvestmentTransaction])] {
        let grouped = Dictionary(grouping: transactions) {
            Calendar.current.startOfDay(for: $0.date)
        }
        return grouped.keys.sorted(by: >).map { date in
            (date, grouped[date] ?? [])
        }
    }

    var body: some View {
        List {
            if transactions.isEmpty {
                emptyState
            } else {
                ForEach(transactionsByDate, id: \.date) { group in
                    Section(group.date.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.items, id: \.investmentTransactionId) { t in
                            txRow(t)
                        }
                    }
                }
            }
        }
        .navigationTitle("Investment Activity")
    }

    @ViewBuilder
    private func txRow(_ t: SDInvestmentTransaction) -> some View {
        let security = t.securityId.flatMap { securitiesById[$0] }
        let ticker = security?.tickerSymbol ?? security?.name ?? ""
        let icon = iconFor(type: t.type, subtype: t.subtype)

        HStack {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(ticker.isEmpty ? (t.name ?? "—") : ticker)
                    .font(.subheadline.weight(.semibold))
                Text((t.subtype ?? t.type ?? "").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let q = t.quantity, q != 0, let p = t.price, p != 0 {
                    Text("\(q.formatted(.number.precision(.fractionLength(0...4)))) × \(p, format: .currency(code: t.currencyCode))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let amt = t.amount {
                Text(amt, format: .currency(code: t.currencyCode))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(amt >= 0 ? Color.primary : Color.green)
            }
        }
    }

    private func iconFor(type: String?, subtype: String?) -> (name: String, color: Color) {
        switch (type, subtype) {
        case (_, "dividend"): return ("dollarsign.circle.fill", .green)
        case ("buy", _): return ("arrow.down.circle.fill", .blue)
        case ("sell", _): return ("arrow.up.circle.fill", .orange)
        case ("fee", _): return ("minus.circle.fill", .red)
        default: return ("arrow.left.arrow.right.circle", .secondary)
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue.opacity(0.6))
                Text("No Investment Activity")
                    .font(.headline)
                Text("Trades, dividends, and fees from your brokerage will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}
