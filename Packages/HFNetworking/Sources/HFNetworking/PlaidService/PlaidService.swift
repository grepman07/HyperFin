import Foundation
import HFDomain
import HFShared

public struct PlaidLinkToken: Codable, Sendable {
    public let linkToken: String
    public let expiration: String
}

public struct PlaidExchangeRequest: Codable, Sendable {
    public let publicToken: String

    public init(publicToken: String) {
        self.publicToken = publicToken
    }
}

public struct PlaidExchangeResponse: Codable, Sendable {
    public let itemId: String
    public let institutionName: String
}

public struct PlaidTransactionResponse: Codable, Sendable {
    public let transactions: [PlaidTransaction]
    public let accounts: [PlaidAccount]
    public let hasMore: Bool
}

public struct PlaidTransaction: Codable, Sendable {
    public let transactionId: String
    public let accountId: String
    public let amount: Double
    public let date: String
    public let merchantName: String?
    public let name: String
    public let category: [String]?
    public let pending: Bool
}

public struct PlaidAccount: Codable, Sendable {
    public let accountId: String
    public let name: String
    public let type: String
    public let subtype: String?
    public let balances: PlaidBalances
}

public struct PlaidBalances: Codable, Sendable {
    public let current: Double?
    public let available: Double?
    public let currencyCode: String?
}

public actor PlaidService {
    private let apiClient: APIClient

    public init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    public func createLinkToken() async throws -> PlaidLinkToken {
        try await apiClient.post(path: "plaid/link-token")
    }

    public func exchangePublicToken(_ publicToken: String) async throws -> PlaidExchangeResponse {
        let body = PlaidExchangeRequest(publicToken: publicToken)
        return try await apiClient.post(path: "plaid/exchange", body: body)
    }

    public func fetchTransactions(since: Date?) async throws -> PlaidTransactionResponse {
        var path = "plaid/transactions"
        if let since {
            let formatter = ISO8601DateFormatter()
            path += "?since=\(formatter.string(from: since))"
        }
        return try await apiClient.get(path: path)
    }

    public func mapToTransaction(_ plaid: PlaidTransaction, accountId: UUID) -> Transaction {
        Transaction(
            plaidTransactionId: plaid.transactionId,
            accountId: accountId,
            amount: Decimal(plaid.amount),
            date: ISO8601DateFormatter().date(from: plaid.date) ?? Date(),
            merchantName: plaid.merchantName,
            originalDescription: plaid.name,
            isPending: plaid.pending
        )
    }

    public func mapToAccount(_ plaid: PlaidAccount, institutionName: String) -> Account {
        let type: AccountType = switch plaid.type {
        case "depository": plaid.subtype == "savings" ? .savings : .checking
        case "credit": .credit
        case "loan": .loan
        case "investment": .investment
        default: .checking
        }

        return Account(
            plaidAccountId: plaid.accountId,
            institutionName: institutionName,
            accountName: plaid.name,
            accountType: type,
            currentBalance: Decimal(plaid.balances.current ?? 0),
            availableBalance: plaid.balances.available.map { Decimal($0) },
            currencyCode: plaid.balances.currencyCode ?? "USD",
            lastSynced: Date()
        )
    }
}
