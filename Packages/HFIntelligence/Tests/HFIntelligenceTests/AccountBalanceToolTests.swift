import XCTest
import HFDomain
@testable import HFIntelligence

// MARK: - Mock repositories
//
// Minimal mocks — only implement what AccountBalanceTool actually calls.
// Anything unused throws fatalError to catch accidental dependencies.

final class MockAccountRepo: AccountRepository, @unchecked Sendable {
    var accounts: [Account] = []

    func fetchAll() async throws -> [Account] { accounts }

    func fetch(id: UUID) async throws -> Account? {
        accounts.first { $0.id == id }
    }
    func save(_ account: Account) async throws { accounts.append(account) }
    func delete(id: UUID) async throws {
        accounts.removeAll { $0.id == id }
    }
    func totalBalance() async throws -> Decimal {
        accounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }
}

final class StubTransactionRepo: TransactionRepository, @unchecked Sendable {
    func fetch(accountId: UUID?, categoryId: UUID?, from: Date?, to: Date?, limit: Int?) async throws -> [Transaction] { [] }
    func fetch(id: UUID) async throws -> Transaction? { nil }
    func save(_ transactions: [Transaction]) async throws {}
    func update(_ transaction: Transaction) async throws {}
    func delete(id: UUID) async throws {}
    func searchByMerchant(_ name: String) async throws -> [Transaction] { [] }
    func spendingTotal(categoryId: UUID?, from: Date, to: Date) async throws -> Decimal { 0 }
    func transactionCount(from: Date, to: Date) async throws -> Int { 0 }
}

final class StubCategoryRepo: CategoryRepository, @unchecked Sendable {
    func fetchAll() async throws -> [SpendingCategory] { [] }
    func fetch(id: UUID) async throws -> SpendingCategory? { nil }
    func save(_ category: SpendingCategory) async throws {}
    func seedSystemCategories() async throws {}
}

final class StubBudgetRepo: BudgetRepository, @unchecked Sendable {
    func fetch(month: Date) async throws -> Budget? { nil }
    func fetchAll() async throws -> [Budget] { [] }
    func save(_ budget: Budget) async throws {}
    func delete(id: UUID) async throws {}
}

// MARK: - AccountBalanceToolTests

final class AccountBalanceToolTests: XCTestCase {

    private func makeAccounts() -> [Account] {
        [
            Account(plaidAccountId: "chk_1", institutionName: "Chase",
                    accountName: "Primary Checking", accountType: .checking,
                    currentBalance: Decimal(1000)),
            Account(plaidAccountId: "sav_1", institutionName: "Chase",
                    accountName: "Savings", accountType: .savings,
                    currentBalance: Decimal(5000)),
            Account(plaidAccountId: "cc_1", institutionName: "Amex",
                    accountName: "Amex Gold", accountType: .credit,
                    currentBalance: Decimal(-450)),  // credit debt
            Account(plaidAccountId: "inv_1", institutionName: "Vanguard",
                    accountName: "IRA", accountType: .investment,
                    currentBalance: Decimal(158000)),
            Account(plaidAccountId: "loan_1", institutionName: "SoFi",
                    accountName: "Student Loan", accountType: .loan,
                    currentBalance: Decimal(-12000)),
        ]
    }

    private func makeRepos(accounts: [Account]) -> ToolRepos {
        let accountRepo = MockAccountRepo()
        accountRepo.accounts = accounts
        return ToolRepos(
            transactions: StubTransactionRepo(),
            categories: StubCategoryRepo(),
            accounts: accountRepo,
            budgets: StubBudgetRepo()
        )
    }

    // MARK: Scope filtering — THE critical test

    func testScope_cash_returnsOnlyCheckingAndSavings() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: ["scope": .string("cash")],
            repos: repos
        ) as! AccountBalanceResult

        // Only checking + savings → 1000 + 5000 = 6000
        XCTAssertEqual(result.totalBalance, Decimal(6000))
        XCTAssertEqual(result.accounts.count, 2)
        XCTAssertEqual(result.scopeLabel, "cash")

        // Verify no investment / credit / loan accounts leaked in
        let types = Set(result.accounts.map { $0.type })
        XCTAssertEqual(types, ["checking", "savings"])
        XCTAssertFalse(types.contains("investment"))
        XCTAssertFalse(types.contains("credit"))
        XCTAssertFalse(types.contains("loan"))
    }

    func testScope_credit_returnsOnlyCredit() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: ["scope": .string("credit")],
            repos: repos
        ) as! AccountBalanceResult

        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.accounts.first?.type, "credit")
        XCTAssertEqual(result.scopeLabel, "credit")
    }

    func testScope_all_returnsEverything() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: ["scope": .string("all")],
            repos: repos
        ) as! AccountBalanceResult

        XCTAssertEqual(result.accounts.count, 5)
        // scopeLabel is nil for "all" — result describes itself as "total"
        XCTAssertNil(result.scopeLabel)
    }

    func testScope_omitted_defaultsToAll() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: [:],
            repos: repos
        ) as! AccountBalanceResult

        // Backward compat: no scope == all accounts
        XCTAssertEqual(result.accounts.count, 5)
    }

    func testScope_invalidValue_defaultsToAll() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: ["scope": .string("bogus")],
            repos: repos
        ) as! AccountBalanceResult

        // Invalid scope is treated as "all" — the model can't break the
        // tool by hallucinating a new scope value.
        XCTAssertEqual(result.accounts.count, 5)
    }

    // MARK: Account name filter + scope compose

    func testScopeAndAccountName_composeCorrectly() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: [
                "scope": .string("cash"),
                "account_name": .string("chase")
            ],
            repos: repos
        ) as! AccountBalanceResult

        // Both filters apply: only Chase accounts AND only cash types
        XCTAssertEqual(result.accounts.count, 2)
        for acc in result.accounts {
            XCTAssertEqual(acc.institution, "Chase")
            XCTAssertTrue(["checking", "savings"].contains(acc.type))
        }
    }

    // MARK: JSON serialization includes scope

    func testToJSON_includesScopeField_whenScoped() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: ["scope": .string("cash")],
            repos: repos
        ) as! AccountBalanceResult

        let json = result.toJSON()
        XCTAssertTrue(json.contains("\"scope\":\"cash\""),
                      "JSON should carry scope for the synthesis model to read: \(json)")
    }

    func testToJSON_omitsScopeField_whenAll() async throws {
        let repos = makeRepos(accounts: makeAccounts())
        let tool = AccountBalanceTool()

        let result = try await tool.execute(
            args: [:],
            repos: repos
        ) as! AccountBalanceResult

        let json = result.toJSON()
        XCTAssertFalse(json.contains("\"scope\""),
                       "JSON should not include scope field for default all: \(json)")
    }
}
