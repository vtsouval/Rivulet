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

    /// Atomically consumes a Bonfire Accounts 2.2 device-pairing secret.
    /// The claim request is anonymous and sends no existing credential. The
    /// issued token is immediately revalidated through `/Users/Me` before it
    /// can cross the Keychain persistence boundary.
    func authenticateWithDevicePairing(
        payload: JellyfinDevicePairingPayload
    ) async throws -> JellyfinAuthenticatedSession {
        guard payload.belongs(to: transport.baseURL) else {
            throw JellyfinAPIError.forbidden(
                message: "This pairing link belongs to another Jellyfin server."
            )
        }

        let result: JellyfinAuthenticationResult = try await transport.request(
            "/plugins/profiles/device-pairing/claim",
            method: .post,
            headers: [
                "Cache-Control": "no-store",
                "Pragma": "no-cache"
            ],
            body: JellyfinDevicePairingClaimRequest(secret: payload.secret)
        )
        let claimed = try makeSession(from: result)
        let user = try await currentUser(accessToken: claimed.accessToken)
        guard user.id == claimed.user.id else {
            throw JellyfinAPIError.unauthorized(message: nil)
        }
        return JellyfinAuthenticatedSession(
            serverURL: claimed.serverURL,
            accessToken: claimed.accessToken,
            user: user,
            serverID: claimed.serverID ?? user.serverID,
            clientIdentity: claimed.clientIdentity,
            authenticatedAt: claimed.authenticatedAt
        )
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
