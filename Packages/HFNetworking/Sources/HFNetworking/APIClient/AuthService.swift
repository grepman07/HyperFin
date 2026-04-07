import Foundation
import HFDomain
import HFShared

public struct AuthTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
}

public struct LoginRequest: Codable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public struct RegisterRequest: Codable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public actor AuthService {
    private let apiClient: APIClient

    public init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    public func register(email: String, password: String) async throws -> AuthTokens {
        let body = RegisterRequest(email: email, password: password)
        let tokens: AuthTokens = try await apiClient.post(path: "auth/register", body: body)
        await apiClient.setTokens(access: tokens.accessToken, refresh: tokens.refreshToken)
        HFLogger.network.info("User registered successfully")
        return tokens
    }

    public func login(email: String, password: String) async throws -> AuthTokens {
        let body = LoginRequest(email: email, password: password)
        let tokens: AuthTokens = try await apiClient.post(path: "auth/login", body: body)
        await apiClient.setTokens(access: tokens.accessToken, refresh: tokens.refreshToken)
        HFLogger.network.info("User logged in successfully")
        return tokens
    }

    public func refresh(token: String) async throws -> AuthTokens {
        struct RefreshBody: Codable { let refreshToken: String }
        let tokens: AuthTokens = try await apiClient.post(path: "auth/refresh", body: RefreshBody(refreshToken: token))
        await apiClient.setTokens(access: tokens.accessToken, refresh: tokens.refreshToken)
        return tokens
    }

    public func logout() async {
        await apiClient.clearTokens()
        HFLogger.network.info("User logged out")
    }
}
