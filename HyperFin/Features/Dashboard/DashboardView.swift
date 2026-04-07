import SwiftUI

struct DashboardView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Total Balance Card
                    VStack(spacing: 8) {
                        Text("Total Balance")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("$0.00")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("Connect a bank account to get started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Monthly Spending Summary
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This Month")
                            .font(.headline)

                        HStack {
                            VStack(alignment: .leading) {
                                Text("Spent")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("$0.00")
                                    .font(.title2.bold())
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("Budget")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("$0.00")
                                    .font(.title2.bold())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Recent Transactions
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent Transactions")
                                .font(.headline)
                            Spacer()
                            Button("See All") {}
                                .font(.subheadline)
                        }

                        Text("No transactions yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("Dashboard")
        }
    }
}
