import Foundation
import SwiftUI
import SwiftData
@preconcurrency import LinkKit
import HFNetworking
import HFDomain
import HFData
import HFShared
import HFIntelligence

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
        let publicToken = success.publicToken
        HFLogger.network.info("Plaid Link success, exchanging token...")

        state = .exchanging
        do {
            let exchange = try await plaidService.exchangePublicToken(publicToken)
            await syncTransactions(institutionName: exchange.institutionName)
        } catch {
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
            let categories = try context.fetch(FetchDescriptor<SDCategory>())
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
            state = .success(accountCount: response.accounts.count)
        } catch {
            state = .error("Failed to sync: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            HFLogger.sync.error("Sync failed: \(error.localizedDescription)")
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
