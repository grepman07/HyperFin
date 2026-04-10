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

    public func request<T: Decodable>(
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

    public func get<T: Decodable>(path: String) async throws -> T {
        try await request(method: "GET", path: path)
    }

    public func post<T: Decodable>(path: String, body: Encodable? = nil) async throws -> T {
        try await request(method: "POST", path: path, body: body)
    }
}
