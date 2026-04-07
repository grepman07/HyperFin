import SwiftUI
import HFNetworking
import HFSecurity
import HFShared

struct AuthView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Binding var isAuthenticated: Bool

    @State private var isLogin = true
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                Text("HyperFin")
                    .font(.largeTitle.bold())
                Text("AI Finance Coach")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)

            // Form
            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(isLogin ? .password : .newPassword)

                if !isLogin {
                    SecureField("Confirm Password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submit()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isLogin ? "Sign In" : "Create Account")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isValid ? .blue : .gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isValid || isLoading)
            }
            .padding(.horizontal, 32)

            Spacer()

            // Toggle login/register
            HStack {
                Text(isLogin ? "Don't have an account?" : "Already have an account?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(isLogin ? "Sign Up" : "Sign In") {
                    withAnimation {
                        isLogin.toggle()
                        errorMessage = nil
                    }
                }
                .font(.subheadline.bold())
            }
            .padding(.bottom, 16)

            // Skip for development
            Button("Skip (Development)") {
                saveDevTokens()
                isAuthenticated = true
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
    }

    private var isValid: Bool {
        let emailValid = email.contains("@") && email.contains(".")
        let passwordValid = password.count >= 8
        if isLogin {
            return emailValid && passwordValid
        }
        return emailValid && passwordValid && password == confirmPassword
    }

    private func submit() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let tokens: AuthTokens
                if isLogin {
                    tokens = try await dependencies.authService.login(email: email, password: password)
                } else {
                    tokens = try await dependencies.authService.register(email: email, password: password)
                }

                // Save tokens to Keychain
                try dependencies.keychain.saveString(key: "accessToken", value: tokens.accessToken)
                try dependencies.keychain.saveString(key: "refreshToken", value: tokens.refreshToken)

                HFLogger.security.info("Auth tokens saved to Keychain")
                isAuthenticated = true
            } catch let error as APIError {
                switch error {
                case .unauthorized:
                    errorMessage = "Invalid email or password"
                case .httpError(let code, let body):
                    errorMessage = body ?? "Server error (\(code))"
                case .networkError:
                    errorMessage = "Unable to connect to server. Check your connection."
                default:
                    errorMessage = "Something went wrong. Please try again."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func saveDevTokens() {
        try? dependencies.keychain.saveString(key: "accessToken", value: "dev-token")
        try? dependencies.keychain.saveString(key: "refreshToken", value: "dev-refresh")
    }
}
