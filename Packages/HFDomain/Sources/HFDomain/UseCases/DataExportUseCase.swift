import Foundation

public struct DataExportUseCase: Sendable {
    private let transactionRepo: TransactionRepository
    private let categoryRepo: CategoryRepository
    private let accountRepo: AccountRepository

    public init(
        transactionRepo: TransactionRepository,
        categoryRepo: CategoryRepository,
        accountRepo: AccountRepository
    ) {
        self.transactionRepo = transactionRepo
        self.categoryRepo = categoryRepo
        self.accountRepo = accountRepo
    }

    public func exportCSV(from: Date, to: Date) async throws -> String {
        let transactions = try await transactionRepo.fetch(
            accountId: nil, categoryId: nil, from: from, to: to, limit: nil
        )
        let categories = try await categoryRepo.fetchAll()
        let accounts = try await accountRepo.fetchAll()

        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.accountName) })

        var csv = "Date,Amount,Category,Merchant,Description,Account\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for txn in transactions.sorted(by: { $0.date > $1.date }) {
            let date = formatter.string(from: txn.date)
            let amount = "\(txn.amount)"
            let category = txn.categoryId.flatMap { categoryMap[$0] } ?? ""
            let merchant = txn.merchantName?.replacingOccurrences(of: ",", with: " ") ?? ""
            let description = txn.originalDescription.replacingOccurrences(of: ",", with: " ")
            let account = accountMap[txn.accountId] ?? ""

            csv += "\(date),\(amount),\(category),\(merchant),\(description),\(account)\n"
        }

        return csv
    }
}
