// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Authentication and connection operations for one Jellyfin server.
///
/// This type deliberately does not persist credentials. The caller owns the
/// Keychain lifecycle for the returned `JellyfinAuthenticatedSession`.
nonisolated struct JellyfinAuthClient: Sendable {
    let transport: JellyfinTransport

    init(transport: JellyfinTransport) {
        self.transport = transport
    }

    func publicSystemInfo() async throws -> JellyfinPublicSystemInfo {
        try await transport.get("/System/Info/Public")
    }

    func authenticate(username: String, password: String) async throws -> JellyfinAuthenticatedSession {
        let result: JellyfinAuthenticationResult = try await transport.post(
            "/Users/AuthenticateByName",
            body: JellyfinUsernamePasswordRequest(username: username, password: password)
        )
        return try makeSession(from: result)
    }

    func currentUser(accessToken: String) async throws -> JellyfinUser {
        try await transport.get("/Users/Me", token: accessToken)
    }

    /// Revalidates a restored token and prevents a valid token for another user
    /// from silently replacing the selected profile.
    func validate(_ session: JellyfinAuthenticatedSession) async throws -> JellyfinUser {
        let user = try await currentUser(accessToken: session.accessToken)
        guard user.id == session.user.id else {
            throw JellyfinAPIError.unauthorized(message: nil)
        }
        return user
    }

    func isQuickConnectEnabled() async throws -> Bool {
        try await transport.get("/QuickConnect/Enabled")
    }

    func startQuickConnect() async throws -> JellyfinQuickConnectState {
        try await transport.post("/QuickConnect/Initiate")
    }

    func pollQuickConnect(secret: String) async throws -> JellyfinQuickConnectState {
        try await transport.get(
            "/QuickConnect/Connect",
            queryItems: [URLQueryItem(name: "secret", value: secret)]
        )
    }

    func authenticateWithQuickConnect(secret: String) async throws -> JellyfinAuthenticatedSession {
        let result: JellyfinAuthenticationResult = try await transport.post(
            "/Users/AuthenticateWithQuickConnect",
            body: JellyfinQuickConnectAuthenticationRequest(secret: secret)
        )
        return try makeSession(from: result)
    }

    /// Authorizes a pending Quick Connect request for the authenticated user.
    /// Jellyfin returns a bare boolean and requires the existing user's token.
    func authorizeQuickConnect(
        code: String,
        userID: String,
        accessToken: String
    ) async throws -> Bool {
        try await transport.post(
            "/QuickConnect/Authorize",
            queryItems: [
                URLQueryItem(name: "code", value: try JellyfinQuickConnectPayload.code(from: code)),
                URLQueryItem(name: "userId", value: userID)
            ],
            token: accessToken
        )
    }

    private func makeSession(from result: JellyfinAuthenticationResult) throws -> JellyfinAuthenticatedSession {
        guard !result.accessToken.isEmpty, !result.user.id.isEmpty else {
            throw JellyfinAPIError.invalidAuthenticationResponse
        }
        return JellyfinAuthenticatedSession(
            serverURL: transport.baseURL,
            accessToken: result.accessToken,
            user: result.user,
            serverID: result.serverID ?? result.user.serverID,
            clientIdentity: transport.clientIdentity,
            authenticatedAt: Date()
        )
    }
}
