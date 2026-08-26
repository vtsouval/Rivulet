// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct JellyfinPasskeyStatus: Decodable, Equatable, Sendable {
    let enabled: Bool
    let hasPasskey: Bool
    let count: Int
    let origin: String?

    enum CodingKeys: String, CodingKey {
        case enabled = "Enabled"
        case hasPasskey = "HasPasskey"
        case count = "Count"
        case origin = "Origin"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        hasPasskey = try values.decodeIfPresent(Bool.self, forKey: .hasPasskey) ?? false
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 0
        origin = try values.decodeIfPresent(String.self, forKey: .origin)
    }
}

nonisolated struct JellyfinPasskeyDescriptor: Decodable, Equatable, Sendable {
    let type: String
    let id: String
    let transports: [String]?
}

nonisolated struct JellyfinPasskeyAssertionOptions: Decodable, Equatable, Sendable {
    let challenge: String
    let timeout: Double?
    let rpId: String?
    let allowCredentials: [JellyfinPasskeyDescriptor]
    let userVerification: String?
}

nonisolated struct JellyfinPasskeyUserOptions: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let displayName: String
}

nonisolated struct JellyfinPasskeyRegistrationOptions: Decodable, Equatable, Sendable {
    let challenge: String
    let rp: JellyfinPasskeyRelyingParty
    let user: JellyfinPasskeyUserOptions
    let excludeCredentials: [JellyfinPasskeyDescriptor]
    let timeout: Double?
    let authenticatorSelection: JellyfinPasskeyAuthenticatorSelection?
}

nonisolated struct JellyfinPasskeyRelyingParty: Decodable, Equatable, Sendable {
    let id: String?
    let name: String
}

nonisolated struct JellyfinPasskeyAuthenticatorSelection: Decodable, Equatable, Sendable {
    let authenticatorAttachment: String?
    let residentKey: String?
    let userVerification: String?
}

nonisolated struct JellyfinPasskeyAuthenticationCeremony: Decodable, Equatable, Sendable {
    let transactionId: String
    let publicKey: JellyfinPasskeyAssertionOptions
    let expiresInSeconds: Int

    enum CodingKeys: String, CodingKey {
        case transactionId = "TransactionId"
        case publicKey = "PublicKey"
        case expiresInSeconds = "ExpiresInSeconds"
    }
}

nonisolated struct JellyfinPasskeyRegistrationCeremony: Decodable, Equatable, Sendable {
    let transactionId: String
    let publicKey: JellyfinPasskeyRegistrationOptions
    let expiresInSeconds: Int

    enum CodingKeys: String, CodingKey {
        case transactionId = "TransactionId"
        case publicKey = "PublicKey"
        case expiresInSeconds = "ExpiresInSeconds"
    }
}

nonisolated struct JellyfinPasskeyCredentialPayload: Encodable, Equatable, Sendable {
    let id: String
    let rawId: String
    let type: String
    let authenticatorAttachment: String?
    let response: JellyfinPasskeyCredentialResponse
    let clientExtensionResults: [String: String]
}

nonisolated struct JellyfinPasskeyCredentialResponse: Encodable, Equatable, Sendable {
    let clientDataJSON: String
    let authenticatorData: String?
    let signature: String?
    let userHandle: String?
    let attestationObject: String?
    let transports: [String]?
}

nonisolated struct JellyfinPasskeyRecord: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let createdUtc: String?
    let lastUsedUtc: String?
    let isBackupEligible: Bool?
    let isBackedUp: Bool?
    let transports: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case createdUtc = "CreatedUtc"
        case lastUsedUtc = "LastUsedUtc"
        case isBackupEligible = "IsBackupEligible"
        case isBackedUp = "IsBackedUp"
        case transports = "Transports"
    }
}

nonisolated private struct BeginAssertion: Encodable, Sendable {
    let userId: String?
}

nonisolated private struct CompleteAssertion: Encodable, Sendable {
    let transactionId: String
    let credential: JellyfinPasskeyCredentialPayload
}

nonisolated private struct BeginRegistration: Encodable, Sendable {
    let currentPassword: String
    let name: String
}

nonisolated private struct CompleteRegistration: Encodable, Sendable {
    let transactionId: String
    let credential: JellyfinPasskeyCredentialPayload
}

nonisolated private struct PasskeyAuthenticationResult: Decodable, Sendable {
    let accessToken: String
    let user: JellyfinUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

/// Bonfire passkey API client. AuthenticationServices owns the credential
/// ceremony; this client only transports its opaque, base64url-encoded result.
/// Passwords are accepted solely for passkey enrollment and are never retained.
nonisolated struct JellyfinPasskeyClient: Sendable {
    let transport: JellyfinTransport

    func status(userID: String? = nil) async throws -> JellyfinPasskeyStatus {
        let query = userID.map { [URLQueryItem(name: "userId", value: $0)] } ?? []
        return try await transport.get(
            "/plugins/profiles/passkeys/status",
            queryItems: query
        )
    }

    func beginAuthentication(
        userID: String? = nil,
        origin: String
    ) async throws -> JellyfinPasskeyAuthenticationCeremony {
        try await transport.request(
            "/plugins/profiles/passkeys/authenticate/options",
            method: .post,
            headers: originHeader(origin),
            body: BeginAssertion(userId: userID)
        )
    }

    func completeAuthentication(
        transactionID: String,
        credential: JellyfinPasskeyCredentialPayload,
        origin: String
    ) async throws -> JellyfinAuthenticatedSession {
        let result: PasskeyAuthenticationResult = try await transport.request(
            "/plugins/profiles/passkeys/authenticate/complete",
            method: .post,
            headers: originHeader(origin),
            body: CompleteAssertion(transactionId: transactionID, credential: credential)
        )
        guard !result.accessToken.isEmpty, !result.user.id.isEmpty else {
            throw JellyfinAPIError.invalidAuthenticationResponse
        }
        return JellyfinAuthenticatedSession(
            serverURL: transport.baseURL,
            accessToken: result.accessToken,
            user: result.user,
            serverID: result.user.serverID,
            clientIdentity: transport.clientIdentity,
            authenticatedAt: Date()
        )
    }

    func records(accessToken: String) async throws -> [JellyfinPasskeyRecord] {
        try await transport.get("/plugins/profiles/passkeys", token: accessToken)
    }

    func beginRegistration(
        currentPassword: String,
        name: String,
        origin: String,
        accessToken: String
    ) async throws -> JellyfinPasskeyRegistrationCeremony {
        try await transport.request(
            "/plugins/profiles/passkeys/register/options",
            method: .post,
            token: accessToken,
            headers: originHeader(origin),
            body: BeginRegistration(currentPassword: currentPassword, name: name)
        )
    }

    func completeRegistration(
        transactionID: String,
        credential: JellyfinPasskeyCredentialPayload,
        origin: String,
        accessToken: String
    ) async throws {
        let _: JellyfinPasskeyRecord = try await transport.request(
            "/plugins/profiles/passkeys/register/complete",
            method: .post,
            token: accessToken,
            headers: originHeader(origin),
            body: CompleteRegistration(transactionId: transactionID, credential: credential)
        )
    }

    func remove(recordID: String, accessToken: String) async throws {
        let _: JellyfinEmptyResponse = try await transport.delete(
            "/plugins/profiles/passkeys/\(recordID)",
            token: accessToken
        )
    }

    private func originHeader(_ origin: String) throws -> [String: String] {
        let url = try validatedOrigin(origin)
        return ["Origin": url.absoluteString]
    }

    /// Bind every native WebAuthn ceremony to the exact origin of the
    /// configured Jellyfin server. A plugin response is untrusted network data;
    /// accepting an arbitrary Origin/RP would turn a malicious server into a
    /// credential-relay surface.
    func validatedOrigin(_ origin: String) throws -> URL {
        guard var components = URLComponents(string: origin),
              components.scheme?.lowercased() == "https",
              let originHost = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let serverComponents = URLComponents(
                url: transport.baseURL,
                resolvingAgainstBaseURL: false
              ),
              serverComponents.scheme?.lowercased() == "https",
              let serverHost = serverComponents.host,
              originHost.caseInsensitiveCompare(serverHost) == .orderedSame,
              Self.effectivePort(components) == Self.effectivePort(serverComponents) else {
            throw JellyfinAPIError.forbidden(
                message: "The passkey origin does not match this Jellyfin server."
            )
        }

        components.scheme = "https"
        components.path = ""
        guard let canonical = components.url else {
            throw JellyfinAPIError.forbidden(
                message: "The passkey origin does not match this Jellyfin server."
            )
        }
        return canonical
    }

    private static func effectivePort(_ components: URLComponents) -> Int {
        components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

nonisolated extension Data {
    var jellyfinBase64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

nonisolated extension String {
    var jellyfinBase64URLData: Data? {
        var value = replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
}
