import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

/// Shows current holdings grouped by (investment) account. Each row reports
/// ticker/name, quantity, market value, and unrealized P/L vs cost basis.
struct HoldingsListView: View {
    @Query(sort: \SDHolding.accountId) private var holdings: [SDHolding]
    @Query private var securities: [SDSecurity]
    @Query private var accounts: [SDAccount]

    private var securitiesById: [String: SDSecurity] {
        Dictionary(uniqueKeysWithValues: securities.map { ($0.securityId, $0) })
    }

    private var accountsByPlaidId: [String: SDAccount] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.plaidAccountId, $0) })
    }

    private var holdingsByAccount: [(accountId: String, accountName: String, items: [SDHolding])] {
        let grouped = Dictionary(grouping: holdings, by: \.accountId)
        return grouped.map { key, value in
            let name = accountsByPlaidId[key]?.accountName ?? "Investment Account"
            return (key, name, value.sorted { ($0.institutionValue ?? 0) > ($1.institutionValue ?? 0) })
        }
        .sorted { $0.accountName < $1.accountName }
    }

    private var totalValue: Double {
        holdings.reduce(0) { $0 + ($1.institutionValue ?? 0) }
    }

    var body: some View {
        List {
            if holdings.isEmpty {
                emptyState
            } else {
                Section {
                    HStack {
                        Text("Total Value")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(totalValue, format: .currency(code: "USD"))
                            .font(.title3.monospacedDigit().bold())
                    }
                }

                ForEach(holdingsByAccount, id: \.accountId) { group in
                    Section(group.accountName) {
                        ForEach(group.items) { h in
                            holdingRow(h)
                        }
                    }
                }
            }
        }
        .navigationTitle("Holdings")
    }

    @ViewBuilder
    private func holdingRow(_ h: SDHolding) -> some View {
        let security = securitiesById[h.securityId]
        let pl = h.institutionValue.flatMap { v in
            h.costBasis.map { v - $0 }
        }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(security?.tickerSymbol ?? security?.name ?? h.securityId.prefix(8).description)
                    .font(.subheadline.weight(.semibold))
                if let name = security?.name, security?.tickerSymbol != nil {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(h.quantity.formatted(.number.precision(.fractionLength(0...4)))) shares")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((h.institutionValue ?? 0), format: .currency(code: h.currencyCode))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                if let pl {
                    Text((pl >= 0 ? "+" : "") + pl.formatted(.currency(code: h.currencyCode)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(pl >= 0 ? .green : .red)
                }
            }
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue.opacity(0.6))
                Text("No Holdings Yet")
                    .font(.headline)
                Text("Link a brokerage account to see your positions here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}
