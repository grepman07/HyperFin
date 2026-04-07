import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

struct TransactionsView: View {
    @Query(sort: \SDTransaction.date, order: .reverse) private var transactions: [SDTransaction]
    @Query(sort: \SDCategory.name) private var categories: [SDCategory]
    @Query(sort: \SDAccount.institutionName) private var accounts: [SDAccount]

    @State private var searchText = ""
    @State private var selectedCategoryId: UUID?
    @State private var selectedAccountId: UUID?
    @State private var selectedTransaction: SDTransaction?
    @State private var showCategoryPicker = false

    private var filteredTransactions: [SDTransaction] {
        var result = transactions

        if let catId = selectedCategoryId {
            result = result.filter { $0.categoryId == catId }
        }

        if let accId = selectedAccountId {
            result = result.filter { $0.accountId == accId }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                ($0.merchantName ?? "").lowercased().contains(query) ||
                $0.originalDescription.lowercased().contains(query)
            }
        }

        return result
    }

    private var groupedByDate: [(String, [SDTransaction])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let grouped = Dictionary(grouping: filteredTransactions) { txn in
            formatter.string(from: txn.date)
        }

        return grouped.sorted { lhs, rhs in
            (lhs.value.first?.date ?? .distantPast) > (rhs.value.first?.date ?? .distantPast)
        }
    }

    private var totalFiltered: Decimal {
        filteredTransactions.filter { $0.amount > 0 }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                transactionList
            }
            .navigationTitle("Transactions")
            .searchable(text: $searchText, prompt: "Search by merchant or description")
            .sheet(isPresented: $showCategoryPicker) {
                if let txn = selectedTransaction {
                    CategoryPickerSheet(
                        transaction: txn,
                        categories: categories
                    )
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    label: "All Categories",
                    isSelected: selectedCategoryId == nil
                ) {
                    selectedCategoryId = nil
                }

                ForEach(usedCategories) { cat in
                    FilterChip(
                        label: cat.name,
                        icon: cat.icon,
                        isSelected: selectedCategoryId == cat.id
                    ) {
                        selectedCategoryId = selectedCategoryId == cat.id ? nil : cat.id
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private var usedCategories: [SDCategory] {
        let usedIds = Set(transactions.compactMap { $0.categoryId })
        return categories.filter { usedIds.contains($0.id) }
    }

    private var transactionList: some View {
        List {
            if !filteredTransactions.isEmpty {
                Section {
                    HStack {
                        Text("\(filteredTransactions.count) transactions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Total: \(totalFiltered.currencyFormatted)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(groupedByDate, id: \.0) { dateStr, txns in
                Section(dateStr) {
                    ForEach(txns) { txn in
                        TransactionRow(
                            transaction: txn,
                            category: categories.first { $0.id == txn.categoryId },
                            account: accounts.first { $0.id == txn.accountId }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedTransaction = txn
                            showCategoryPicker = true
                        }
                    }
                }
            }

            if filteredTransactions.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "No transactions yet" : "No results for \"\(searchText)\"")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Transaction Row

struct TransactionRow: View {
    let transaction: SDTransaction
    let category: SDCategory?
    let account: SDAccount?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category?.icon ?? "circle")
                .font(.body)
                .foregroundStyle(Color.blue)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchantName ?? transaction.originalDescription)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let cat = category {
                        Text(cat.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    if let acc = account {
                        Text(acc.accountName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                let isIncome = transaction.amount < 0
                Text(isIncome ? "+\((-transaction.amount).currencyFormatted)" : transaction.amount.currencyFormatted)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(isIncome ? .green : .primary)

                if transaction.isPending {
                    Text("Pending")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
    }
}

// MARK: - Category Picker Sheet

struct CategoryPickerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let transaction: SDTransaction
    let categories: [SDCategory]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.merchantName ?? transaction.originalDescription)
                            .font(.headline)
                        Text(transaction.amount.currencyFormatted)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Select Category") {
                    ForEach(categories) { cat in
                        Button {
                            recategorize(to: cat)
                        } label: {
                            HStack {
                                Image(systemName: cat.icon)
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                Text(cat.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if transaction.categoryId == cat.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                if transaction.categoryId != nil {
                    Section {
                        Button(role: .destructive) {
                            recategorize(to: nil)
                        } label: {
                            Label("Remove Category", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Categorize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func recategorize(to category: SDCategory?) {
        transaction.categoryId = category?.id
        transaction.isUserCategorized = category != nil

        // Also update the merchant mapping cache for future categorization
        if let merchantName = transaction.merchantName, let catId = category?.id {
            let normalized = merchantName.normalizedMerchantName
            let mapping = MerchantMapping(
                merchantName: normalized,
                categoryId: catId,
                confidence: 1.0,
                source: .userCorrection
            )
            modelContext.insert(SDMerchantMapping(from: mapping))
        }

        try? modelContext.save()
        dismiss()
    }
}
