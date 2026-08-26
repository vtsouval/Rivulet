// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Non-secret QR payload used to hand a pending Jellyfin Quick Connect request
/// from a television/new device to an already authenticated client. It accepts
/// both Rivulet deep links and Bonfire's browser approval route. The access
/// token and Quick Connect secret are deliberately never encoded.
nonisolated struct JellyfinQuickConnectPayload: Codable, Hashable, Sendable {
    static let scheme = "rivulet"
    static let host = "jellyfin"
    static let path = "/quick-connect"

    let serverURL: URL
    let code: String

    init(serverURL: URL, code: String) throws {
        self.serverURL = try JellyfinServerURL.normalize(serverURL)
        self.code = try Self.normalizedCode(code)
    }

    init(url: URL) throws {
        if url.scheme?.lowercased() == Self.scheme {
            guard url.host?.lowercased() == Self.host,
                  url.path.lowercased() == Self.path,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let server = components.queryItems?.first(where: { $0.name == "server" })?.value,
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                throw JellyfinAPIError.invalidResponse
            }
            self.serverURL = try JellyfinServerURL.normalize(server)
            self.code = try Self.normalizedCode(code)
            return
        }

        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              let route = URLComponents(string: "https://approval.invalid\(fragment.hasPrefix("/") ? fragment : "/\(fragment)")"),
              route.path.lowercased() == "/quickconnect",
              let code = route.queryItems?.first(where: { $0.name.lowercased() == "code" })?.value else {
            throw JellyfinAPIError.invalidResponse
        }

        components.fragment = nil
        components.query = nil
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/web") {
            path.removeLast(4)
        }
        components.path = path
        guard let server = components.url else { throw JellyfinAPIError.invalidResponse }
        self.serverURL = try JellyfinServerURL.normalize(server)
        self.code = try Self.normalizedCode(code)
    }

    /// Browser-compatible QR target used by Bonfire 2.1 and later. A phone's
    /// regular camera can open this route and Bonfire asks for explicit user
    /// confirmation before authorizing the short-lived code.
    var approvalURL: URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = "\(path == "/" ? "" : path)/web/"
        components.fragment = "/quickconnect?code=\(code)"
        return components.url!
    }

    /// App deep link retained for direct Rivulet-to-Rivulet handoff.
    var appURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = Self.path
        components.queryItems = [
            URLQueryItem(name: "server", value: serverURL.absoluteString),
            URLQueryItem(name: "code", value: code)
        ]
        // The constants and normalized values above always form a valid URL.
        return components.url!
    }

    /// QR call sites use the browser-compatible approval route by default.
    var url: URL { approvalURL }

    func belongs(to session: JellyfinAuthenticatedSession) -> Bool {
        guard let sessionURL = try? JellyfinServerURL.normalize(session.serverURL) else { return false }
        return Self.originAndPath(sessionURL) == Self.originAndPath(serverURL)
    }

    static func code(from scannedValue: String) throws -> String {
        let trimmed = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return try JellyfinQuickConnectPayload(url: url).code
        }
        return try normalizedCode(trimmed)
    }

    private static func normalizedCode(_ value: String) throws -> String {
        let normalized = value
            .filter { !$0.isWhitespace && $0 != "-" }
            .uppercased()
        guard (4...12).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) && $0.isASCII
              }) else {
            throw JellyfinAPIError.invalidResponse
        }
        return normalized
    }

    private static func originAndPath(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString.lowercased() ?? url.absoluteString.lowercased()
    }
}
