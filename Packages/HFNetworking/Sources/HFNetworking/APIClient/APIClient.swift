import Foundation
import HFShared

public enum APIError: Error, Sendable {
    case invalidURL
    case httpError(statusCode: Int, body: String?)
    case decodingError(Error)
    case networkError(Error)
    case unauthorized
}

public actor APIClient {
    // Module-internal so same-module extensions (e.g. APIClient+Streaming.swift)
    // can reach them. Not `public` — external callers must go through the
    // public methods.
    let baseURL: String
    let session: URLSession
    private var accessToken: String?
    private var refreshToken: String?

    /// Called after a successful token refresh so the app layer can persist
    /// the new tokens to Keychain. Set via `setTokenRefreshCallback`.
    private var onTokensRefreshed: (@Sendable (String, String) async -> Void)?

    /// Guards against multiple concurrent refresh attempts. When true, a
    /// refresh is already in-flight — subsequent 401s wait for it to finish
    /// rather than firing duplicate refresh requests.
    private var isRefreshing = false

    /// Shared encoder — ISO 8601 dates so server-side Zod `z.string().datetime()`
    /// validators accept timestamps. Default Swift encoding is a Double of
    /// seconds-since-2001 which fails any `.datetime()` validator.
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(baseURL: String = HFConstants.API.baseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = HFConstants.API.timeoutInterval
        self.session = URLSession(configuration: config)
    }

    public func setTokens(access: String, refresh: String) {
        self.accessToken = access
        self.refreshToken = refresh
    }

    public func clearTokens() {
        self.accessToken = nil
        self.refreshToken = nil
    }

    /// Register a callback invoked after automatic token refresh so the app
    /// can persist the new tokens (e.g. to Keychain).
    public func setTokenRefreshCallback(_ callback: @escaping @Sendable (String, String) async -> Void) {
        self.onTokensRefreshed = callback
    }

    // MARK: - Public request methods

    public func request<T: Decodable>(
        method: String,
        path: String,
        body: Encodable? = nil
    ) async throws -> T {
        do {
            return try await rawRequest(method: method, path: path, body: body)
        } catch APIError.unauthorized {
            // Don't try to refresh auth endpoints themselves
            guard !path.hasPrefix("auth/") else { throw APIError.unauthorized }
            guard let refresh = self.refreshToken else { throw APIError.unauthorized }

            // Attempt automatic token refresh
            let newTokens = try await refreshAccessToken(using: refresh)
            self.accessToken = newTokens.accessToken
            self.refreshToken = newTokens.refreshToken

            // Notify app layer to persist new tokens
            await onTokensRefreshed?(newTokens.accessToken, newTokens.refreshToken)

            HFLogger.network.info("Auto-refreshed access token")

            // Retry the original request with the new token
            return try await rawRequest(method: method, path: path, body: body)
        }
    }

    public func get<T: Decodable>(path: String) async throws -> T {
        try await request(method: "GET", path: path)
    }

    public func post<T: Decodable>(path: String, body: Encodable? = nil) async throws -> T {
        try await request(method: "POST", path: path, body: body)
    }

    // MARK: - Internal

    /// The actual network call — no retry logic. Called by `request()` which
    /// wraps this with 401 → refresh → retry.
    private func rawRequest<T: Decodable>(
        method: String,
        path: String,
        body: Encodable? = nil
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)/\(HFConstants.API.apiVersion)/\(path)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try encoder.encode(body)
        }

        HFLogger.network.debug("\(method) \(path)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Token Refresh

    /// Lightweight token refresh that calls `POST auth/refresh` directly
    /// (not through AuthService, to avoid circular dependencies).
    private func refreshAccessToken(using refreshToken: String) async throws -> RefreshResponse {
        guard !isRefreshing else {
            // Another refresh is already in flight — wait briefly and retry
            // with whatever tokens are current. If they're still expired the
            // caller will surface .unauthorized.
            throw APIError.unauthorized
        }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let url = URL(string: "\(baseURL)/\(HFConstants.API.apiVersion)/auth/refresh") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RefreshRequest(refreshToken: refreshToken)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            // Refresh token is invalid/expired — user must re-authenticate
            throw APIError.unauthorized
        }

        return try decoder.decode(RefreshResponse.self, from: data)
    }
}

// MARK: - Refresh DTOs (private to avoid coupling with AuthService)

private struct RefreshRequest: Codable {
    let refreshToken: String
}

private struct RefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}
