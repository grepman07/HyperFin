import Foundation
import SwiftUI
import SwiftData
@preconcurrency import LinkKit
import HFNetworking
import HFDomain
import HFData
import HFShared
import HFIntelligence
import HFSecurity

enum PlaidLinkState: Equatable {
    case idle
    case loading
    case presenting
    case exchanging
    case syncing
    case success(accountCount: Int)
    case error(String)

    static func == (lhs: PlaidLinkState, rhs: PlaidLinkState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.presenting, .presenting),
             (.exchanging, .exchanging), (.syncing, .syncing):
            return true
        case (.success(let a), .success(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

@Observable
@MainActor
final class PlaidLinkHandler {
    private(set) var state: PlaidLinkState = .idle
    var showPlaidLink = false
    var showMockFlow = false
    var errorMessage: String?

    private let plaidService: PlaidService
    private let accountRepo: SwiftDataAccountRepository
    private let transactionRepo: SwiftDataTransactionRepository
    private let modelContainer: ModelContainer

    private(set) var plaidHandler: Handler?
    private var linkToken: String?

    init(
        plaidService: PlaidService,
        accountRepo: SwiftDataAccountRepository,
        transactionRepo: SwiftDataTransactionRepository,
        modelContainer: ModelContainer
    ) {
        self.plaidService = plaidService
        self.accountRepo = accountRepo
        self.transactionRepo = transactionRepo
        self.modelContainer = modelContainer
    }

    func startLinking() async {
        state = .loading
        errorMessage = nil
        SecurityAuditLogger.logAccess(action: "plaid_link_started", resource: "plaid_link_token")

        do {
            let linkTokenResponse = try await plaidService.createLinkToken()
            self.linkToken = linkTokenResponse.linkToken

            // If it's a mock token, use simulated flow
            if linkTokenResponse.linkToken.hasPrefix("link-sandbox-mock") {
                state = .presenting
                showMockFlow = true
                return
            }

            // Real Plaid Link
            try openPlaidLink(token: linkTokenResponse.linkToken)
        } catch {
            state = .error("Failed to start bank linking: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            HFLogger.network.error("Plaid link token failed: \(error.localizedDescription)")
        }
    }

    private func openPlaidLink(token: String) throws {
        var config = LinkTokenConfiguration(token: token) { [weak self] result in
            Task { @MainActor in
                await self?.handleLinkSuccess(result)
            }
        }
        config.onExit = { [weak self] exit in
            Task { @MainActor in
                self?.handleLinkExit(exit)
            }
        }

        let result = Plaid.create(config)
        switch result {
        case .success(let handler):
            self.plaidHandler = handler
            state = .presenting
            showPlaidLink = true
        case .failure(let error):
            state = .error("Failed to create Plaid Link: \(error.localizedDescription)")
        }
    }

    private func handleLinkSuccess(_ success: LinkSuccess) async {
        // Dismiss the fullScreenCover immediately so SwiftUI doesn't call
        // the binding's `set` closure (which used to call dismiss() and
        // nuke the in-flight state machine).
        showPlaidLink = false

        let publicToken = success.publicToken
        HFLogger.network.info("Plaid Link success, exchanging token...")
        SecurityAuditLogger.logAccess(
            action: "plaid_public_token_received",
            resource: "plaid_public_token",
            detail: "institution=\(success.metadata.institution.name)"
        )

        state = .exchanging
        do {
            let exchange = try await plaidService.exchangePublicToken(publicToken)
            SecurityAuditLogger.logAccess(
                action: "plaid_token_exchanged",
                resource: "plaid_item",
                detail: "institution=\(exchange.institutionName)"
            )
            await syncTransactions(institutionName: exchange.institutionName)
        } catch {
            SecurityAuditLogger.logAccess(
                action: "plaid_exchange_failed",
                resource: "plaid_public_token",
                detail: error.localizedDescription
            )
            state = .error("Failed to link account: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func handleLinkExit(_ exit: LinkExit) {
        if let error = exit.error {
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        } else {
            state = .idle
        }
        showPlaidLink = false
    }

    // Called from mock flow or after real Plaid exchange
    func completeMockFlow() async {
        showMockFlow = false
        state = .exchanging

        do {
            let exchange = try await plaidService.exchangePublicToken("mock-public-token")
            await syncTransactions(institutionName: exchange.institutionName)
        } catch {
            state = .error("Failed to link: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func syncTransactions(institutionName: String) async {
        state = .syncing
        HFLogger.sync.info("Syncing transactions...")

        do {
            let response = try await plaidService.fetchTransactions(since: nil)
            let context = modelContainer.mainContext

            // Clear existing sample data
            let existingAccounts = try context.fetch(FetchDescriptor<SDAccount>())
            for account in existingAccounts { context.delete(account) }
            let existingTxns = try context.fetch(FetchDescriptor<SDTransaction>())
            for txn in existingTxns { context.delete(txn) }

            // Save accounts
            var plaidToLocalId: [String: UUID] = [:]
            for plaidAccount in response.accounts {
                let account = await plaidService.mapToAccount(plaidAccount, institutionName: institutionName)
                plaidToLocalId[plaidAccount.accountId] = account.id
                context.insert(SDAccount(from: account))
            }

            // Save transactions
            let _ = try context.fetch(FetchDescriptor<SDCategory>())
            let categoryEngine = CategorizationRuleEngine()

            var transactionCount = 0
            for plaidTxn in response.transactions {
                guard let localAccountId = plaidToLocalId[plaidTxn.accountId] else { continue }
                var txn = await plaidService.mapToTransaction(plaidTxn, accountId: localAccountId)

                // Categorize using rule engine
                let description = txn.merchantName ?? txn.originalDescription
                if let catId = categoryEngine.categorize(description: description) {
                    txn = Transaction(
                        id: txn.id,
                        plaidTransactionId: txn.plaidTransactionId,
                        accountId: txn.accountId,
                        amount: txn.amount,
                        date: txn.date,
                        merchantName: txn.merchantName,
                        originalDescription: txn.originalDescription,
                        categoryId: catId,
                        isUserCategorized: false,
                        isPending: txn.isPending
                    )
                }

                context.insert(SDTransaction(from: txn))
                transactionCount += 1
            }

            try context.save()
            HFLogger.sync.info("Synced \(response.accounts.count) accounts, \(transactionCount) transactions")

            // Fire-and-forget: also pull investments + liabilities. These are
            // best-effort — if the institution doesn't support the product,
            // the server returns 200 with empty data; if something else
            // breaks, we swallow the error so a successful cash-tx sync
            // still surfaces to the user as a completed link.
            Task { await self.syncHoldings() }
            Task { await self.syncInvestmentTransactions() }
            Task { await self.syncLiabilities() }

            state = .success(accountCount: response.accounts.count)
        } catch {
            state = .error("Failed to sync: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            HFLogger.sync.error("Sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Investments / Liabilities sync

    /// Pull current holdings + their securities into SwiftData. Errors are
    /// logged but not surfaced — a partial-product-support institution will
    /// still have a healthy cash-tx sync, and the holdings list view just
    /// stays empty until the user links a brokerage.
    private func syncHoldings() async {
        SecurityAuditLogger.logAccess(action: "plaid_investments_synced", resource: "holdings")
        do {
            let response = try await plaidService.fetchHoldings()
            let context = modelContainer.mainContext

            // Upsert securities first (holdings reference them via securityId)
            for dto in response.securities {
                let sid = dto.securityId
                var fetch = FetchDescriptor<SDSecurity>(predicate: #Predicate { $0.securityId == sid })
                fetch.fetchLimit = 1
                if let existing = try context.fetch(fetch).first {
                    existing.tickerSymbol = dto.tickerSymbol
                    existing.name = dto.name
                    existing.type = dto.type
                    existing.closePrice = dto.closePrice
                    existing.currencyCode = dto.currencyCode
                    existing.updatedAt = Date()
                } else {
                    let domain = await plaidService.mapToSecurity(dto)
                    context.insert(SDSecurity(from: domain))
                }
            }

            // Replace holdings wholesale — Plaid returns the full snapshot.
            let existing = try context.fetch(FetchDescriptor<SDHolding>())
            for h in existing { context.delete(h) }
            for dto in response.holdings {
                let domain = await plaidService.mapToHolding(dto)
                context.insert(SDHolding(from: domain))
            }
            try context.save()
            HFLogger.sync.info("Synced \(response.holdings.count) holdings")
        } catch {
            HFLogger.sync.error("Holdings sync skipped: \(error.localizedDescription)")
        }
    }

    /// Pull investment transactions for the default 24-month window on first
    /// link (server-side default). Incremental syncs on subsequent calls are
    /// handled by the server via `investments_last_synced_date`.
    private func syncInvestmentTransactions() async {
        SecurityAuditLogger.logAccess(
            action: "plaid_investment_transactions_synced",
            resource: "investment_transactions"
        )
        do {
            let response = try await plaidService.fetchInvestmentTransactions()
            let context = modelContainer.mainContext

            for dto in response.securities {
                let sid = dto.securityId
                var fetch = FetchDescriptor<SDSecurity>(predicate: #Predicate { $0.securityId == sid })
                fetch.fetchLimit = 1
                if try context.fetch(fetch).first == nil {
                    let domain = await plaidService.mapToSecurity(dto)
                    context.insert(SDSecurity(from: domain))
                }
            }

            for dto in response.transactions {
                let txId = dto.investmentTransactionId
                var fetch = FetchDescriptor<SDInvestmentTransaction>(
                    predicate: #Predicate { $0.investmentTransactionId == txId }
                )
                fetch.fetchLimit = 1
                guard try context.fetch(fetch).first == nil else { continue }
                let domain = await plaidService.mapToInvestmentTransaction(dto)
                context.insert(SDInvestmentTransaction(from: domain))
            }
            try context.save()
            HFLogger.sync.info("Synced \(response.transactions.count) investment transactions")
        } catch {
            HFLogger.sync.error("Investment transactions sync skipped: \(error.localizedDescription)")
        }
    }

    /// Pull credit/mortgage/student liability data. We store the raw JSON
    /// payload per (account, kind) and decode on-demand in the view layer.
    private func syncLiabilities() async {
        SecurityAuditLogger.logAccess(action: "plaid_liabilities_synced", resource: "liabilities")
        do {
            let response = try await plaidService.fetchLiabilities()
            let context = modelContainer.mainContext

            // Wholesale replace — Plaid returns the full current state.
            let existing = try context.fetch(FetchDescriptor<SDLiability>())
            for l in existing { context.delete(l) }

            // Map DTOs → domain models before persisting so the stored JSON
            // matches what SDLiability.toLiability() decodes.
            let encoder = JSONEncoder()
            for dto in response.credit {
                let domain = CreditLiability(
                    accountId: dto.accountId,
                    lastStatementBalance: dto.lastStatementBalance,
                    minimumPaymentAmount: dto.minimumPaymentAmount,
                    nextPaymentDueDate: dto.nextPaymentDueDate,
                    lastPaymentAmount: dto.lastPaymentAmount,
                    lastPaymentDate: dto.lastPaymentDate,
                    purchaseAPR: dto.aprs?.first(where: { $0.aprType == "purchase_apr" })?.aprPercentage
                        ?? dto.aprs?.first?.aprPercentage,
                    isOverdue: dto.isOverdue
                )
                if let data = try? encoder.encode(domain) {
                    context.insert(SDLiability(accountId: dto.accountId, kind: "credit", payload: data))
                }
            }
            for dto in response.mortgage {
                let domain = MortgageLiability(
                    accountId: dto.accountId,
                    interestRatePercentage: dto.interestRate?.percentage,
                    interestRateType: dto.interestRate?.type,
                    nextPaymentDueDate: dto.nextPaymentDueDate,
                    nextMonthlyPayment: dto.nextMonthlyPayment,
                    maturityDate: dto.maturityDate,
                    originationPrincipalAmount: dto.originationPrincipalAmount,
                    ytdInterestPaid: dto.ytdInterestPaid,
                    ytdPrincipalPaid: dto.ytdPrincipalPaid,
                    pastDueAmount: dto.pastDueAmount
                )
                if let data = try? encoder.encode(domain) {
                    context.insert(SDLiability(accountId: dto.accountId, kind: "mortgage", payload: data))
                }
            }
            for dto in response.student {
                let domain = StudentLiability(
                    accountId: dto.accountId,
                    loanName: dto.loanName,
                    interestRatePercentage: dto.interestRatePercentage,
                    minimumPaymentAmount: dto.minimumPaymentAmount,
                    nextPaymentDueDate: dto.nextPaymentDueDate,
                    expectedPayoffDate: dto.expectedPayoffDate,
                    outstandingInterestAmount: dto.outstandingInterestAmount,
                    originationPrincipalAmount: dto.originationPrincipalAmount,
                    ytdInterestPaid: dto.ytdInterestPaid,
                    ytdPrincipalPaid: dto.ytdPrincipalPaid,
                    loanStatusType: dto.loanStatus?.type
                )
                if let data = try? encoder.encode(domain) {
                    context.insert(SDLiability(accountId: dto.accountId, kind: "student", payload: data))
                }
            }
            try context.save()
            HFLogger.sync.info(
                "Synced liabilities: \(response.credit.count) credit, \(response.mortgage.count) mortgage, \(response.student.count) student"
            )
        } catch {
            HFLogger.sync.error("Liabilities sync skipped: \(error.localizedDescription)")
        }
    }

    func dismiss() {
        state = .idle
        showPlaidLink = false
        showMockFlow = false
        errorMessage = nil
    }
}

// MARK: - Plaid Link UIKit Wrapper

struct PlaidLinkViewController: UIViewControllerRepresentable {
    let handler: Handler

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        DispatchQueue.main.async {
            self.handler.open(presentUsing: .viewController(vc))
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
