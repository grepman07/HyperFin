import SwiftUI

struct TransactionsView: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Text("No transactions yet. Connect a bank account to see your transactions.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            .searchable(text: $searchText, prompt: "Search transactions")
            .navigationTitle("Transactions")
        }
    }
}
