import SwiftUI

struct LockScreenView: View {
    @Binding var isAuthenticated: Bool
    @State private var showError = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "brain.head.profile.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("HyperFin")
                    .font(.largeTitle.bold())
                Text("AI Finance Coach")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                authenticate()
            } label: {
                Label("Unlock with Face ID", systemImage: "faceid")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 40)

            if showError {
                Text("Authentication failed. Please try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer().frame(height: 40)
        }
        .onAppear {
            authenticate()
        }
    }

    private func authenticate() {
        // In production: use BiometricAuthManager
        // For development, auto-authenticate:
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            isAuthenticated = true
        }
    }
}
