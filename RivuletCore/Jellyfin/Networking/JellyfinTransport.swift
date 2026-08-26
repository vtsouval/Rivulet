// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum JellyfinHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// Explicit response type for Jellyfin mutations that return HTTP 204 or an
/// empty body. Using this instead of teaching every DTO that "no bytes" is a
/// valid value keeps empty-success handling deliberate at each call site.
nonisolated struct JellyfinEmptyResponse: Decodable, Equatable, Sendable {
    init() {}
}

nonisolated enum JellyfinAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidServerURL
    case invalidResponse
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound(message: String?)
    case server(statusCode: Int, message: String?)
    case http(statusCode: Int, message: String?)
    case transport(code: Int, message: String)
    case decoding(message: String)
    case invalidAuthenticationResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter an HTTPS Jellyfin address, or explicit HTTP for a private local server."
        case .invalidResponse:
            return "The Jellyfin server returned an invalid response."
        case .unauthorized(let message):
            return message ?? "The Jellyfin credentials or access token were rejected."
        case .forbidden(let message):
            return message ?? "This Jellyfin user does not have permission to perform that action."
        case .notFound(let message):
            return message ?? "The requested Jellyfin resource was not found."
        case .server(_, let message):
            return message ?? "The Jellyfin server could not complete the request."
        case .http(let statusCode, let message):
            return message ?? "Jellyfin returned HTTP \(statusCode)."
        case .transport(_, let message):
            return message
        case .decoding:
            return "The Jellyfin response could not be read."
        case .invalidAuthenticationResponse:
            return "Jellyfin authenticated the request without returning a usable session."
        }
    }
}

/// Low-level Jellyfin JSON transport shared by authentication and future
/// provider services. Actor isolation also keeps Foundation's stateful JSON
/// encoder and decoder from being used concurrently by parallel shelf loads.
actor JellyfinTransport {
    nonisolated let baseURL: URL
    nonisolated let clientIdentity: JellyfinClientIdentity

    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        serverURL: URL,
        clientIdentity: JellyfinClientIdentity,
        session: URLSession = JellyfinTransport.defaultSession(),
        requestTimeout: TimeInterval = 30
    ) throws {
        self.baseURL = try JellyfinServerURL.normalize(serverURL)
        self.clientIdentity = clientIdentity
        self.session = session
        self.requestTimeout = requestTimeout
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    init(
        serverURL: String,
        clientIdentity: JellyfinClientIdentity,
        session: URLSession = JellyfinTransport.defaultSession(),
        requestTimeout: TimeInterval = 30
    ) throws {
        self.baseURL = try JellyfinServerURL.normalize(serverURL)
        self.clientIdentity = clientIdentity
        self.session = session
        self.requestTimeout = requestTimeout
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func get<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: .get, queryItems: queryItems, token: token)
    }

    func post<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: .post, queryItems: queryItems, token: token, body: body)
    }

    func post<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: .post, queryItems: queryItems, token: token)
    }

    func put<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: .put, queryItems: queryItems, token: token, body: body)
    }

    func put<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: .put, queryItems: queryItems, token: token)
    }

    func delete<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: .delete, queryItems: queryItems, token: token, body: body)
    }

    func delete<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: .delete, queryItems: queryItems, token: token)
    }

    /// Generic JSON request used by provider endpoints that do not warrant a
    /// dedicated transport method. `body` is optional for every HTTP verb, so
    /// PUT/DELETE endpoints with unusual Jellyfin payloads do not need a second
    /// encoder or URLSession implementation.
    func request<Response: Decodable & Sendable>(
        _ path: String,
        method: JellyfinHTTPMethod,
        queryItems: [URLQueryItem] = [],
        token: String? = nil,
        headers: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil
    ) async throws -> Response {
        try Task.checkCancellation()

        let url = try endpointURL(path: path, queryItems: queryItems)
        let encodedBody: Data?
        do {
            encodedBody = try body.map { try encoder.encode($0) }
        } catch {
            throw JellyfinAPIError.decoding(message: String(describing: error))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = encodedBody
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentity.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        if encodedBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw JellyfinAPIError.transport(code: error.errorCode, message: error.localizedDescription)
        } catch {
            let nsError = error as NSError
            throw JellyfinAPIError.transport(code: nsError.code, message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.httpError(statusCode: httpResponse.statusCode, data: data)
        }
        guard httpResponse.expectedContentLength <= 64 * 1024 * 1024,
              data.count <= 64 * 1024 * 1024 else {
            throw JellyfinAPIError.http(
                statusCode: 413,
                message: "The Jellyfin response exceeded the safe client limit."
            )
        }

        if data.isEmpty, Response.self == JellyfinEmptyResponse.self,
           let empty = JellyfinEmptyResponse() as? Response {
            return empty
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw JellyfinAPIError.decoding(message: String(describing: error))
        }
    }

    @discardableResult
    func requestEmpty(
        _ path: String,
        method: JellyfinHTTPMethod,
        queryItems: [URLQueryItem] = [],
        token: String? = nil,
        headers: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil
    ) async throws -> JellyfinEmptyResponse {
        try await request(
            path,
            method: method,
            queryItems: queryItems,
            token: token,
            headers: headers,
            body: body
        )
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var url = baseURL
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        guard !queryItems.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinAPIError.invalidServerURL
        }
        components.queryItems = queryItems
        guard let result = components.url else {
            throw JellyfinAPIError.invalidServerURL
        }
        return result
    }

    private static func httpError(statusCode: Int, data: Data) -> JellyfinAPIError {
        let message = responseMessage(from: data)
        switch statusCode {
        case 401:
            return .unauthorized(message: message)
        case 403:
            return .forbidden(message: message)
        case 404:
            return .notFound(message: message)
        case 500...599:
            return .server(statusCode: statusCode, message: message)
        default:
            return .http(statusCode: statusCode, message: message)
        }
    }

    private static func responseMessage(from data: Data) -> String? {
        if let problem = try? JSONDecoder().decode(JellyfinProblemDetails.self, from: data),
           let message = problem.bestMessage {
            return limitedMessage(message)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return limitedMessage(text)
    }

    private static func limitedMessage(_ value: String) -> String? {
        let collapsed = value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(300))
    }
}

nonisolated private struct JellyfinProblemDetails: Decodable {
    let title: String?
    let detail: String?
    let message: String?
    let uppercaseMessage: String?

    var bestMessage: String? {
        uppercaseMessage ?? message ?? detail ?? title
    }

    enum CodingKeys: String, CodingKey {
        case title
        case detail
        case message
        case uppercaseMessage = "Message"
    }
}
