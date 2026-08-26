// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Non-secret portion of a Jellyfin login. The matching token is stored in
/// Keychain through `CredentialRegistry`, never in UserDefaults.
struct JellyfinSessionDescriptor: Codable, Sendable {
    let serverURL: URL
    let user: JellyfinUser
    let serverID: String?
    let clientIdentity: JellyfinClientIdentity
    let authenticatedAt: Date

    init(session: JellyfinAuthenticatedSession) {
        serverURL = session.serverURL
        user = session.user
        serverID = session.serverID
        clientIdentity = session.clientIdentity
        authenticatedAt = session.authenticatedAt
    }

    var providerID: String {
        if let serverID, !serverID.isEmpty { return "jellyfin:\(serverID)" }
        return "jellyfin:\(serverURL.host ?? serverURL.absoluteString)"
    }

    var credentialScope: CredentialScope {
        .serverUser(providerID: providerID, userID: user.id)
    }

    func session(accessToken: String) -> JellyfinAuthenticatedSession {
        JellyfinAuthenticatedSession(
            serverURL: serverURL,
            accessToken: accessToken,
            user: user,
            serverID: serverID,
            clientIdentity: clientIdentity,
            authenticatedAt: authenticatedAt
        )
    }
}

/// Storage boundary for Jellyfin session state. Implementations must keep the
/// descriptor and token in separate stores: the descriptor is non-secret
/// metadata, while the token belongs in a credential store such as Keychain.
///
/// Keeping this boundary injectable also lets the rollback and sign-out paths
/// be verified without reading or writing the device's real Keychain.
@MainActor
protocol JellyfinSessionPersisting: AnyObject {
    func descriptorData() -> Data?
    func saveDescriptorData(_ data: Data) throws
    func removeDescriptorData()

    func token(for scope: CredentialScope) -> String?
    func setToken(_ token: String, for scope: CredentialScope) async throws
    func clearToken(for scope: CredentialScope) async

    func registerServer(_ credential: ServerCredential)
    func unregisterServer(providerID: String)
}

@MainActor
private final class JellyfinLiveSessionPersistence: JellyfinSessionPersisting {
    private let defaults: UserDefaults
    private let descriptorKey: String

    init(defaults: UserDefaults = .standard, descriptorKey: String) {
        self.defaults = defaults
        self.descriptorKey = descriptorKey
    }

    func descriptorData() -> Data? {
        defaults.data(forKey: descriptorKey)
    }

    func saveDescriptorData(_ data: Data) throws {
        defaults.set(data, forKey: descriptorKey)
    }

    func removeDescriptorData() {
        defaults.removeObject(forKey: descriptorKey)
    }

    func token(for scope: CredentialScope) -> String? {
        CredentialRegistry.shared.token(for: scope)
    }

    func setToken(_ token: String, for scope: CredentialScope) async throws {
        try await CredentialRegistry.shared.setToken(token, for: scope)
    }

    func clearToken(for scope: CredentialScope) async {
        await CredentialRegistry.shared.clearToken(for: scope)
    }

    func registerServer(_ credential: ServerCredential) {
        CredentialRegistry.shared.registerServer(credential)
    }

    func unregisterServer(providerID: String) {
        CredentialRegistry.shared.unregisterServer(providerID: providerID)
    }
}

/// Owns the active Jellyfin login and its revocable token lifecycle.
///
/// A transient network error never erases a valid login. Only explicit
/// sign-out or an authentication rejection removes the token.
@Observable @MainActor
final class JellyfinSessionStore {
    private enum Keys {
        static let activeSession = "jellyfin.activeSession.v1"
        static let deviceID = "jellyfin.deviceID.v1"
    }

    typealias SessionValidator = (JellyfinAuthenticatedSession) async throws -> JellyfinUser

    static let shared = JellyfinSessionStore(
        persistence: JellyfinLiveSessionPersistence(descriptorKey: Keys.activeSession)
    )

    private(set) var currentSession: JellyfinAuthenticatedSession?
    private(set) var isValidating = false
    private(set) var lastValidationError: JellyfinAPIError?

    private let persistence: any JellyfinSessionPersisting
    private let validator: SessionValidator

    var hasCredentials: Bool { currentSession != nil }

    init(
        persistence: any JellyfinSessionPersisting,
        validator: SessionValidator? = nil
    ) {
        self.persistence = persistence
        self.validator = validator ?? Self.validate
        currentSession = Self.restoreSession(using: persistence)
    }

    /// Stable, installation-scoped identity used in Jellyfin's MediaBrowser
    /// authorization header. It intentionally is not a hardware identifier.
    static func clientIdentity() -> JellyfinClientIdentity {
        let defaults = UserDefaults.standard
        let deviceID: String
        if let stored = defaults.string(forKey: Keys.deviceID), !stored.isEmpty {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: Keys.deviceID)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        return JellyfinClientIdentity(
            device: "Apple TV",
            deviceID: deviceID,
            version: version
        )
    }

    func persist(_ session: JellyfinAuthenticatedSession) async throws {
        let descriptor = JellyfinSessionDescriptor(session: session)
        let previousSession = currentSession
        let previous = previousSession.map(JellyfinSessionDescriptor.init(session:))

        try await persistence.setToken(
            session.accessToken,
            for: descriptor.credentialScope
        )

        do {
            let encoded = try JSONEncoder().encode(descriptor)
            try persistence.saveDescriptorData(encoded)
        } catch {
            // If this login replaces a token under the same scope, restore the
            // previous credential. Clearing it would corrupt an otherwise valid
            // active session when only metadata persistence failed.
            if let previousSession,
               previous?.credentialScope == descriptor.credentialScope {
                try? await persistence.setToken(
                    previousSession.accessToken,
                    for: descriptor.credentialScope
                )
            } else {
                await persistence.clearToken(for: descriptor.credentialScope)
            }
            throw MediaProviderError.backendSpecific(
                underlying: "Failed to persist the Jellyfin session metadata"
            )
        }

        if let previous,
           previous.credentialScope != descriptor.credentialScope {
            await persistence.clearToken(for: previous.credentialScope)
        }

        persistence.registerServer(
            ServerCredential(
                id: descriptor.providerID,
                displayName: session.user.name,
                userID: session.user.id,
                kind: .jellyfin
            )
        )
        currentSession = session
        lastValidationError = nil
    }

    /// Revalidates the restored token without caching. Unauthorized sessions
    /// are revoked locally; connectivity failures retain the session so an
    /// offline launch does not silently sign the user out.
    @discardableResult
    func validateCurrentSession() async -> Bool {
        guard let session = currentSession, !isValidating else { return false }
        isValidating = true
        defer { isValidating = false }

        do {
            let user = try await validator(session)
            let refreshedSession = JellyfinAuthenticatedSession(
                serverURL: session.serverURL,
                accessToken: session.accessToken,
                user: user,
                serverID: session.serverID ?? user.serverID,
                clientIdentity: session.clientIdentity,
                authenticatedAt: session.authenticatedAt
            )
            try await persist(refreshedSession)
            lastValidationError = nil
            return true
        } catch is CancellationError {
            lastValidationError = nil
            return false
        } catch let error as JellyfinAPIError {
            lastValidationError = error
            if case .unauthorized = error { await signOut() }
            return false
        } catch {
            lastValidationError = .transport(
                code: (error as NSError).code,
                message: error.localizedDescription
            )
            return false
        }
    }

    func signOut() async {
        // Use persisted metadata as a fallback. A Keychain read can fail during
        // restoration, leaving no in-memory session, but explicit sign-out must
        // still delete the credential identified by the descriptor.
        let descriptor = currentSession.map(JellyfinSessionDescriptor.init(session:))
            ?? Self.persistedDescriptor(using: persistence)
        if let descriptor {
            await persistence.clearToken(for: descriptor.credentialScope)
            persistence.unregisterServer(providerID: descriptor.providerID)
        }
        persistence.removeDescriptorData()
        currentSession = nil
        lastValidationError = nil
    }

    private static func validate(_ session: JellyfinAuthenticatedSession) async throws -> JellyfinUser {
        let transport = try JellyfinTransport(
            serverURL: session.serverURL,
            clientIdentity: session.clientIdentity
        )
        return try await JellyfinAuthClient(transport: transport).validate(session)
    }

    private static func persistedDescriptor(
        using persistence: any JellyfinSessionPersisting
    ) -> JellyfinSessionDescriptor? {
        guard let data = persistence.descriptorData() else { return nil }
        return try? JSONDecoder().decode(JellyfinSessionDescriptor.self, from: data)
    }

    private static func restoreSession(
        using persistence: any JellyfinSessionPersisting
    ) -> JellyfinAuthenticatedSession? {
        guard
            let descriptor = persistedDescriptor(using: persistence),
            let token = persistence.token(for: descriptor.credentialScope),
            !token.isEmpty
        else { return nil }
        return descriptor.session(accessToken: token)
    }
}
