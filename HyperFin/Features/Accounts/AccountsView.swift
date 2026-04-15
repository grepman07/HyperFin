import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

struct AccountsView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Query(sort: \SDAccount.institutionName) private var accounts: [SDAccount]
    @State private var linkHandler: PlaidLinkHandler?

    private var totalBalance: Decimal {
        accounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }

    var body: some View {
        NavigationStack {
            List {
                if accounts.isEmpty && linkHandler?.state == .idle {
                    emptyState
                } else {
                    if !accounts.isEmpty {
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

                        Section("Wealth & Liabilities") {
                            NavigationLink {
                                HoldingsListView()
                            } label: {
                                Label("Holdings", systemImage: "chart.line.uptrend.xyaxis")
                            }
                            NavigationLink {
                                InvestmentTransactionsListView()
                            } label: {
                                Label("Investment Activity", systemImage: "chart.xyaxis.line")
                            }
                            NavigationLink {
                                LiabilitiesListView()
                            } label: {
                                Label("Liabilities", systemImage: "creditcard.and.123")
                            }
                        }
                    }

                    if let handler = linkHandler {
                        statusSection(handler)
                    }

                    Section {
                        Button {
                            startLinking()
                        } label: {
                            Label("Connect Bank Account", systemImage: "plus.circle.fill")
                        }
                        .disabled(linkHandler?.state == .loading || linkHandler?.state == .syncing)
                    }
                }
            }
            .navigationTitle("Accounts")
            .onAppear {
                if linkHandler == nil {
                    linkHandler = PlaidLinkHandler(
                        plaidService: dependencies.plaidService,
                        accountRepo: dependencies.accountRepo,
                        transactionRepo: dependencies.transactionRepo,
                        modelContainer: dependencies.modelContainer
                    )
                }
            }
            .sheet(isPresented: Binding(
                get: { linkHandler?.showMockFlow ?? false },
                set: { _ in }
            )) {
                mockBankSelectionSheet
            }
            .fullScreenCover(isPresented: Binding(
                get: { linkHandler?.showPlaidLink ?? false },
                set: { _ in linkHandler?.dismiss() }
            )) {
                if let handler = linkHandler?.plaidHandler {
                    PlaidLinkViewController(handler: handler)
                        .ignoresSafeArea()
                }
            }
            .alert("Error", isPresented: Binding(
                get: { linkHandler?.errorMessage != nil },
                set: { _ in linkHandler?.dismiss() }
            )) {
                Button("OK") { linkHandler?.dismiss() }
            } message: {
                Text(linkHandler?.errorMessage ?? "An error occurred")
            }
        }
    }

    private func startLinking() {
        guard let handler = linkHandler else { return }
        Task {
            await handler.startLinking()
        }
    }

    @ViewBuilder
    private func statusSection(_ handler: PlaidLinkHandler) -> some View {
        switch handler.state {
        case .loading:
            Section {
                HStack {
                    ProgressView()
                    Text("Connecting to bank...")
                        .padding(.leading, 8)
                }
            }
        case .exchanging:
            Section {
                HStack {
                    ProgressView()
                    Text("Linking account...")
                        .padding(.leading, 8)
                }
            }
        case .syncing:
            Section {
                HStack {
                    ProgressView()
                    Text("Syncing transactions...")
                        .padding(.leading, 8)
                }
            }
        case .success(let count):
            Section {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(count) account\(count == 1 ? "" : "s") linked successfully!")
                }
            }
        default:
            EmptyView()
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

    // Mock bank selection (used when no real Plaid credentials)
    private var mockBankSelectionSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select a bank to simulate linking. In production, Plaid Link handles this securely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Popular Banks") {
                    ForEach(["Chase", "Bank of America", "Wells Fargo", "Citi"], id: \.self) { bank in
                        Button {
                            Task {
                                await linkHandler?.completeMockFlow()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "building.columns.fill")
                                    .foregroundStyle(.blue)
                                Text(bank)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Connect Bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        linkHandler?.dismiss()
                    }
                }
            }
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
                Text("Securely connect your bank accounts. Your financial data stays on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Connect Bank Account") { startLinking() }
                    .buttonStyle(.borderedProminent)

                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption2)
                    Text("Bank-grade encryption  |  On-device processing")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}
