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

// MARK: - Investments

public struct PlaidHoldingsResponse: Codable, Sendable {
    public let holdings: [PlaidHoldingDTO]
    public let securities: [PlaidSecurityDTO]
    public let accounts: [PlaidInvestmentAccountDTO]
}

public struct PlaidHoldingDTO: Codable, Sendable {
    public let accountId: String
    public let securityId: String
    public let quantity: Double
    public let institutionPrice: Double?
    public let institutionValue: Double?
    public let costBasis: Double?
    public let currencyCode: String
}

public struct PlaidSecurityDTO: Codable, Sendable {
    public let securityId: String
    public let tickerSymbol: String?
    public let name: String?
    public let type: String?
    public let closePrice: Double?
    public let currencyCode: String
}

public struct PlaidInvestmentAccountDTO: Codable, Sendable {
    public let accountId: String
    public let name: String
    public let type: String
    public let subtype: String?
}

public struct PlaidInvestmentTransactionsResponse: Codable, Sendable {
    public let transactions: [PlaidInvestmentTransactionDTO]
    public let securities: [PlaidSecurityDTO]
    public let accounts: [PlaidInvestmentAccountDTO]
}

public struct PlaidInvestmentTransactionDTO: Codable, Sendable {
    public let investmentTransactionId: String
    public let accountId: String
    public let securityId: String?
    public let date: String
    public let name: String?
    public let type: String?
    public let subtype: String?
    public let quantity: Double?
    public let price: Double?
    public let fees: Double?
    public let amount: Double?
    public let currencyCode: String
}

// MARK: - Liabilities

/// The server returns one array per kind plus a flat `accounts` list. We
/// keep this mirror struct thin: the iOS layer only renders a handful of
/// fields per kind, so the DTOs decode exactly those (matching the server's
/// snake_case JSON via CodingKeys).
public struct PlaidLiabilitiesResponse: Codable, Sendable {
    public let credit: [PlaidCreditDTO]
    public let mortgage: [PlaidMortgageDTO]
    public let student: [PlaidStudentDTO]
    public let accounts: [PlaidInvestmentAccountDTO]
}

public struct PlaidCreditDTO: Codable, Sendable {
    public let accountId: String
    public let lastStatementBalance: Double?
    public let minimumPaymentAmount: Double?
    public let nextPaymentDueDate: String?
    public let lastPaymentAmount: Double?
    public let lastPaymentDate: String?
    public let aprs: [PlaidAPRDTO]?
    public let isOverdue: Bool?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case lastStatementBalance = "last_statement_balance"
        case minimumPaymentAmount = "minimum_payment_amount"
        case nextPaymentDueDate = "next_payment_due_date"
        case lastPaymentAmount = "last_payment_amount"
        case lastPaymentDate = "last_payment_date"
        case aprs, isOverdue = "is_overdue"
    }
}

public struct PlaidAPRDTO: Codable, Sendable {
    public let aprPercentage: Double?
    public let aprType: String?
    public let balanceSubjectToApr: Double?

    enum CodingKeys: String, CodingKey {
        case aprPercentage = "apr_percentage"
        case aprType = "apr_type"
        case balanceSubjectToApr = "balance_subject_to_apr"
    }
}

public struct PlaidMortgageDTO: Codable, Sendable {
    public let accountId: String
    public let interestRate: PlaidInterestRateDTO?
    public let nextPaymentDueDate: String?
    public let nextMonthlyPayment: Double?
    public let maturityDate: String?
    public let originationPrincipalAmount: Double?
    public let ytdInterestPaid: Double?
    public let ytdPrincipalPaid: Double?
    public let pastDueAmount: Double?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case interestRate = "interest_rate"
        case nextPaymentDueDate = "next_payment_due_date"
        case nextMonthlyPayment = "next_monthly_payment"
        case maturityDate = "maturity_date"
        case originationPrincipalAmount = "origination_principal_amount"
        case ytdInterestPaid = "ytd_interest_paid"
        case ytdPrincipalPaid = "ytd_principal_paid"
        case pastDueAmount = "past_due_amount"
    }
}

public struct PlaidInterestRateDTO: Codable, Sendable {
    public let percentage: Double?
    public let type: String?
}

public struct PlaidStudentDTO: Codable, Sendable {
    public let accountId: String
    public let loanName: String?
    public let interestRatePercentage: Double?
    public let minimumPaymentAmount: Double?
    public let nextPaymentDueDate: String?
    public let expectedPayoffDate: String?
    public let outstandingInterestAmount: Double?
    public let originationPrincipalAmount: Double?
    public let ytdInterestPaid: Double?
    public let ytdPrincipalPaid: Double?
    public let loanStatus: PlaidStudentLoanStatusDTO?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case loanName = "loan_name"
        case interestRatePercentage = "interest_rate_percentage"
        case minimumPaymentAmount = "minimum_payment_amount"
        case nextPaymentDueDate = "next_payment_due_date"
        case expectedPayoffDate = "expected_payoff_date"
        case outstandingInterestAmount = "outstanding_interest_amount"
        case originationPrincipalAmount = "origination_principal_amount"
        case ytdInterestPaid = "ytd_interest_paid"
        case ytdPrincipalPaid = "ytd_principal_paid"
        case loanStatus = "loan_status"
    }
}

public struct PlaidStudentLoanStatusDTO: Codable, Sendable {
    public let type: String?
    public let endDate: String?

    enum CodingKeys: String, CodingKey {
        case type
        case endDate = "end_date"
    }
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

    // MARK: - Investments / Liabilities

    public func fetchHoldings() async throws -> PlaidHoldingsResponse {
        try await apiClient.get(path: "investments/holdings")
    }

    public func fetchInvestmentTransactions(
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> PlaidInvestmentTransactionsResponse {
        var path = "investments/transactions"
        var params: [String] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        if let startDate { params.append("start_date=\(fmt.string(from: startDate))") }
        if let endDate { params.append("end_date=\(fmt.string(from: endDate))") }
        if !params.isEmpty { path += "?\(params.joined(separator: "&"))" }
        return try await apiClient.get(path: path)
    }

    public func fetchLiabilities() async throws -> PlaidLiabilitiesResponse {
        try await apiClient.get(path: "liabilities")
    }

    public func mapToHolding(_ dto: PlaidHoldingDTO) -> Holding {
        Holding(
            accountId: dto.accountId,
            securityId: dto.securityId,
            quantity: dto.quantity,
            institutionPrice: dto.institutionPrice,
            institutionValue: dto.institutionValue,
            costBasis: dto.costBasis,
            currencyCode: dto.currencyCode
        )
    }

    public func mapToSecurity(_ dto: PlaidSecurityDTO) -> Security {
        Security(
            securityId: dto.securityId,
            tickerSymbol: dto.tickerSymbol,
            name: dto.name,
            type: dto.type,
            closePrice: dto.closePrice,
            currencyCode: dto.currencyCode
        )
    }

    public func mapToInvestmentTransaction(_ dto: PlaidInvestmentTransactionDTO) -> InvestmentTransaction {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return InvestmentTransaction(
            investmentTransactionId: dto.investmentTransactionId,
            accountId: dto.accountId,
            securityId: dto.securityId,
            date: fmt.date(from: dto.date) ?? Date(),
            name: dto.name,
            type: dto.type,
            subtype: dto.subtype,
            quantity: dto.quantity,
            price: dto.price,
            fees: dto.fees,
            amount: dto.amount,
            currencyCode: dto.currencyCode
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
