import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

struct AccountsView: View {
    @Query(sort: \SDAccount.institutionName) private var accounts: [SDAccount]

    private var totalBalance: Decimal {
        accounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }

    var body: some View {
        NavigationStack {
            List {
                if accounts.isEmpty {
                    emptyState
                } else {
                    Section {
                        HStack {
                            Text("Net Worth")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(totalBalance.currencyFormatted)
                                .font(.title3.bold())
                        }
                    }

                    Section("Accounts") {
                        ForEach(accounts) { account in
                            accountRow(account)
                        }
                    }

                    Section {
                        Button {
                            // Trigger Plaid Link
                        } label: {
                            Label("Connect Another Account", systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
        }
    }

    private func accountRow(_ account: SDAccount) -> some View {
        HStack {
            Image(systemName: iconForType(account.accountTypeRaw))
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.accountName)
                    .font(.subheadline.weight(.medium))
                Text(account.institutionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(account.currentBalance.currencyFormatted)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(account.currentBalance < 0 ? .red : .primary)
                if let synced = account.lastSynced {
                    Text("Synced \(synced.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "checking": "building.columns.fill"
        case "savings": "banknote.fill"
        case "credit": "creditcard.fill"
        case "loan": "doc.text.fill"
        case "investment": "chart.line.uptrend.xyaxis"
        default: "dollarsign.circle.fill"
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "building.columns")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue.opacity(0.6))
                Text("No Accounts Linked")
                    .font(.headline)
                Text("Connect your bank accounts via Plaid.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Connect Bank Account") {}
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}
