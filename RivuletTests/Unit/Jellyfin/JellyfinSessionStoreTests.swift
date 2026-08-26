// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

final class JellyfinSessionStoreTests: XCTestCase {
    @MainActor
    func testPersistSeparatesDescriptorFromSecretTokenAndRestoresSession() async throws {
        let persistence = JellyfinInMemorySessionPersistence()
        let store = JellyfinSessionStore(persistence: persistence)
        let session = makeSession(token: "top-secret-access-token")

        try await store.persist(session)

        let descriptorData = try XCTUnwrap(persistence.storedDescriptorData)
        let descriptorText = try XCTUnwrap(String(data: descriptorData, encoding: .utf8))
        XCTAssertFalse(descriptorText.contains(session.accessToken))
        XCTAssertFalse(descriptorText.localizedCaseInsensitiveContains("accessToken"))

        let descriptor = try JSONDecoder().decode(JellyfinSessionDescriptor.self, from: descriptorData)
        XCTAssertEqual(descriptor.serverURL, session.serverURL)
        XCTAssertEqual(persistence.tokens[descriptor.credentialScope], session.accessToken)

        let restored = JellyfinSessionStore(persistence: persistence)
        XCTAssertEqual(restored.currentSession, session)
    }

    @MainActor
    func testMetadataFailureRestoresPreviousTokenForSameCredentialScope() async throws {
        let persistence = JellyfinInMemorySessionPersistence()
        let oldSession = makeSession(token: "old-token")
        let oldDescriptor = JellyfinSessionDescriptor(session: oldSession)
        persistence.storedDescriptorData = try JSONEncoder().encode(oldDescriptor)
        persistence.tokens[oldDescriptor.credentialScope] = oldSession.accessToken

        let store = JellyfinSessionStore(persistence: persistence)
        persistence.shouldFailDescriptorSave = true

        do {
            try await store.persist(makeSession(token: "replacement-token"))
            XCTFail("Expected descriptor persistence to fail")
        } catch {
            XCTAssertEqual(store.currentSession, oldSession)
            XCTAssertEqual(persistence.tokens[oldDescriptor.credentialScope], oldSession.accessToken)
        }
    }

    @MainActor
    func testSignOutClearsCredentialUsingDescriptorWhenTokenCannotBeRestored() async throws {
        let persistence = JellyfinInMemorySessionPersistence()
        let descriptor = JellyfinSessionDescriptor(session: makeSession(token: "not-installed"))
        persistence.storedDescriptorData = try JSONEncoder().encode(descriptor)

        let store = JellyfinSessionStore(persistence: persistence)
        XCTAssertNil(store.currentSession)

        await store.signOut()

        XCTAssertEqual(persistence.clearedScopes, [descriptor.credentialScope])
        XCTAssertEqual(persistence.unregisteredProviderIDs, [descriptor.providerID])
        XCTAssertNil(persistence.storedDescriptorData)
    }

    @MainActor
    func testUnauthorizedValidationRevokesPersistedSession() async throws {
        let persistence = JellyfinInMemorySessionPersistence()
        let session = makeSession(token: "revoked-token")
        let descriptor = JellyfinSessionDescriptor(session: session)
        persistence.storedDescriptorData = try JSONEncoder().encode(descriptor)
        persistence.tokens[descriptor.credentialScope] = session.accessToken
        let store = JellyfinSessionStore(
            persistence: persistence,
            validator: { _ in
                throw JellyfinAPIError.unauthorized(message: nil)
            }
        )

        let isValid = await store.validateCurrentSession()

        XCTAssertFalse(isValid)
        XCTAssertNil(store.currentSession)
        XCTAssertNil(persistence.tokens[descriptor.credentialScope])
        XCTAssertNil(persistence.storedDescriptorData)
    }

    @MainActor
    func testCancelledValidationRetainsSessionAndCredential() async throws {
        let persistence = JellyfinInMemorySessionPersistence()
        let session = makeSession(token: "retained-token")
        let descriptor = JellyfinSessionDescriptor(session: session)
        persistence.storedDescriptorData = try JSONEncoder().encode(descriptor)
        persistence.tokens[descriptor.credentialScope] = session.accessToken
        let store = JellyfinSessionStore(
            persistence: persistence,
            validator: { _ in throw CancellationError() }
        )

        let isValid = await store.validateCurrentSession()

        XCTAssertFalse(isValid)
        XCTAssertEqual(store.currentSession, session)
        XCTAssertEqual(persistence.tokens[descriptor.credentialScope], session.accessToken)
        XCTAssertNotNil(persistence.storedDescriptorData)
    }

    @MainActor
    private func makeSession(token: String) -> JellyfinAuthenticatedSession {
        JellyfinAuthenticatedSession(
            serverURL: URL(string: "https://media.example.com/jellyfin")!,
            accessToken: token,
            user: JellyfinUser(
                id: "user-1",
                name: "Vasilis",
                serverID: "server-1",
                primaryImageTag: nil,
                hasPassword: true
            ),
            serverID: "server-1",
            clientIdentity: JellyfinClientIdentity(
                device: "Test Apple TV",
                deviceID: "test-device",
                version: "1.0"
            ),
            authenticatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

@MainActor
private final class JellyfinInMemorySessionPersistence: JellyfinSessionPersisting {
    var storedDescriptorData: Data?
    var tokens: [CredentialScope: String] = [:]
    var shouldFailDescriptorSave = false
    var clearedScopes: [CredentialScope] = []
    var registeredServers: [ServerCredential] = []
    var unregisteredProviderIDs: [String] = []

    func descriptorData() -> Data? {
        storedDescriptorData
    }

    func saveDescriptorData(_ data: Data) throws {
        if shouldFailDescriptorSave { throw PersistenceError.expectedFailure }
        storedDescriptorData = data
    }

    func removeDescriptorData() {
        storedDescriptorData = nil
    }

    func token(for scope: CredentialScope) -> String? {
        tokens[scope]
    }

    func setToken(_ token: String, for scope: CredentialScope) async throws {
        tokens[scope] = token
    }

    func clearToken(for scope: CredentialScope) async {
        clearedScopes.append(scope)
        tokens.removeValue(forKey: scope)
    }

    func registerServer(_ credential: ServerCredential) {
        registeredServers.append(credential)
    }

    func unregisterServer(providerID: String) {
        unregisteredProviderIDs.append(providerID)
    }

    private enum PersistenceError: Error {
        case expectedFailure
    }
}
