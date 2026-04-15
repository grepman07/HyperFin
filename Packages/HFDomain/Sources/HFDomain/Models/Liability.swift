import Foundation

// Plaid's liabilities payloads diverge sharply between credit / mortgage /
// student. Rather than flatten them into one struct with half the fields
// always nil, we model each as its own struct and wrap them in an enum.
// Only the fields the iOS UI actually renders are decoded — everything else
// stays in the opaque raw payload on the server side.

public struct CreditLiability: Sendable, Equatable, Codable {
    public let accountId: String
    public let lastStatementBalance: Double?
    public let minimumPaymentAmount: Double?
    public let nextPaymentDueDate: String?
    public let lastPaymentAmount: Double?
    public let lastPaymentDate: String?
    public let purchaseAPR: Double?
    public let isOverdue: Bool?

    public init(
        accountId: String,
        lastStatementBalance: Double? = nil,
        minimumPaymentAmount: Double? = nil,
        nextPaymentDueDate: String? = nil,
        lastPaymentAmount: Double? = nil,
        lastPaymentDate: String? = nil,
        purchaseAPR: Double? = nil,
        isOverdue: Bool? = nil
    ) {
        self.accountId = accountId
        self.lastStatementBalance = lastStatementBalance
        self.minimumPaymentAmount = minimumPaymentAmount
        self.nextPaymentDueDate = nextPaymentDueDate
        self.lastPaymentAmount = lastPaymentAmount
        self.lastPaymentDate = lastPaymentDate
        self.purchaseAPR = purchaseAPR
        self.isOverdue = isOverdue
    }
}

public struct MortgageLiability: Sendable, Equatable, Codable {
    public let accountId: String
    public let interestRatePercentage: Double?
    public let interestRateType: String?
    public let nextPaymentDueDate: String?
    public let nextMonthlyPayment: Double?
    public let maturityDate: String?
    public let originationPrincipalAmount: Double?
    public let ytdInterestPaid: Double?
    public let ytdPrincipalPaid: Double?
    public let pastDueAmount: Double?

    public init(
        accountId: String,
        interestRatePercentage: Double? = nil,
        interestRateType: String? = nil,
        nextPaymentDueDate: String? = nil,
        nextMonthlyPayment: Double? = nil,
        maturityDate: String? = nil,
        originationPrincipalAmount: Double? = nil,
        ytdInterestPaid: Double? = nil,
        ytdPrincipalPaid: Double? = nil,
        pastDueAmount: Double? = nil
    ) {
        self.accountId = accountId
        self.interestRatePercentage = interestRatePercentage
        self.interestRateType = interestRateType
        self.nextPaymentDueDate = nextPaymentDueDate
        self.nextMonthlyPayment = nextMonthlyPayment
        self.maturityDate = maturityDate
        self.originationPrincipalAmount = originationPrincipalAmount
        self.ytdInterestPaid = ytdInterestPaid
        self.ytdPrincipalPaid = ytdPrincipalPaid
        self.pastDueAmount = pastDueAmount
    }
}

public struct StudentLiability: Sendable, Equatable, Codable {
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
    public let loanStatusType: String?

    public init(
        accountId: String,
        loanName: String? = nil,
        interestRatePercentage: Double? = nil,
        minimumPaymentAmount: Double? = nil,
        nextPaymentDueDate: String? = nil,
        expectedPayoffDate: String? = nil,
        outstandingInterestAmount: Double? = nil,
        originationPrincipalAmount: Double? = nil,
        ytdInterestPaid: Double? = nil,
        ytdPrincipalPaid: Double? = nil,
        loanStatusType: String? = nil
    ) {
        self.accountId = accountId
        self.loanName = loanName
        self.interestRatePercentage = interestRatePercentage
        self.minimumPaymentAmount = minimumPaymentAmount
        self.nextPaymentDueDate = nextPaymentDueDate
        self.expectedPayoffDate = expectedPayoffDate
        self.outstandingInterestAmount = outstandingInterestAmount
        self.originationPrincipalAmount = originationPrincipalAmount
        self.ytdInterestPaid = ytdInterestPaid
        self.ytdPrincipalPaid = ytdPrincipalPaid
        self.loanStatusType = loanStatusType
    }
}

public enum Liability: Sendable, Equatable {
    case credit(CreditLiability)
    case mortgage(MortgageLiability)
    case student(StudentLiability)

    public var accountId: String {
        switch self {
        case .credit(let c): return c.accountId
        case .mortgage(let m): return m.accountId
        case .student(let s): return s.accountId
        }
    }
}
