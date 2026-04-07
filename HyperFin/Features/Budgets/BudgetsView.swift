import SwiftUI

struct BudgetsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue.opacity(0.6))

                Text("No Budget Yet")
                    .font(.title2.bold())

                Text("Connect your bank accounts and HyperFin will analyze your spending to suggest a personalized budget.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)

                Button {
                    // Navigate to account linking
                } label: {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 40)

                Spacer()
            }
            .navigationTitle("Budgets")
        }
    }
}
