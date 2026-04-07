import SwiftUI

struct AccountsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "building.columns")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue.opacity(0.6))

                Text("No Accounts Linked")
                    .font(.title2.bold())

                Text("Securely connect your bank accounts via Plaid. Your financial data stays on this device — it's never stored on our servers.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)

                Button {
                    // Trigger Plaid Link flow
                } label: {
                    Label("Connect Bank Account", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 40)

                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                    Text("Bank-grade encryption  |  On-device processing")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Spacer()
            }
            .navigationTitle("Accounts")
        }
    }
}
