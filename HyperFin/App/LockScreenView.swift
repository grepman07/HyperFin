import SwiftUI
import HFSecurity
import HFShared

struct LockScreenView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Binding var isAuthenticated: Bool
    @State private var showAuth = false
    @State private var showError = false
    @State private var hasCheckedTokens = false

    var body: some View {
        Group {
            if showAuth {
                AuthView(isAuthenticated: $isAuthenticated)
            } else {
                biometricScreen
            }
        }
        .onAppear {
            checkExistingSession()
        }
    }

    private var biometricScreen: some View {
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
    }

    private func checkExistingSession() {
        guard !hasCheckedTokens else { return }
        hasCheckedTokens = true

        // Check if we have saved tokens
        if let token = try? dependencies.keychain.loadString(key: "accessToken"), !token.isEmpty {
            // Have tokens — show biometric unlock
            authenticate()
        } else {
            // No tokens — show login/register
            showAuth = true
        }
    }

    private func authenticate() {
        Task {
            do {
                let success = try await dependencies.biometricAuth.authenticate()
                if success {
                    isAuthenticated = true
                }
            } catch BiometricError.notAvailable {
                // No biometrics — auto-authenticate in development
                isAuthenticated = true
            } catch {
                showError = true
            }
        }
    }
}
