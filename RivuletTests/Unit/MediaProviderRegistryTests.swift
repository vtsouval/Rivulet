// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

@MainActor
final class MediaProviderRegistryTests: XCTestCase {
    func testFallbackPrimaryProviderIsDeterministicAndPreservesPlexPriority() throws {
        let (registry, defaults, suiteName) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jellyfin = try makeJellyfinProvider()
        let plex = makePlexProvider(id: "server-b")

        registry.register(jellyfin)
        registry.register(plex)

        XCTAssertEqual(registry.enabledProviders().map(\.id), [plex.id, jellyfin.id])
        XCTAssertEqual(registry.primaryProviderID, plex.id)
    }

    func testExplicitPrimaryProviderPersistsAcrossRegistryRestoration() throws {
        let (first, defaults, suiteName) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jellyfin = try makeJellyfinProvider()
        let plex = makePlexProvider(id: "server-b")
        first.register(plex)
        first.register(jellyfin)
        first.selectPrimaryProvider(jellyfin.id)

        let restored = MediaProviderRegistry(defaults: defaults, preferredPrimaryProviderKey: "primary")
        restored.register(jellyfin)
        restored.register(plex)

        XCTAssertEqual(restored.preferredPrimaryProviderID, jellyfin.id)
        XCTAssertEqual(restored.primaryProviderID, jellyfin.id)
    }

    func testRemovingOneAuthenticatedBackendPreservesTheOther() throws {
        let (registry, defaults, suiteName) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jellyfin = try makeJellyfinProvider()
        let plex = makePlexProvider(id: "server-b")
        registry.reconcileAuthenticatedProvider(plex, for: .plex)
        registry.reconcileAuthenticatedProvider(jellyfin, for: .jellyfin)

        registry.reconcileAuthenticatedProvider(nil, for: .plex)

        XCTAssertNil(registry.provider(for: plex.id))
        XCTAssertEqual(registry.provider(for: jellyfin.id)?.kind, .jellyfin)
    }

    func testReplacingServerRemovesOnlyStaleProviderOfSameKind() throws {
        let (registry, defaults, suiteName) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldPlex = makePlexProvider(id: "old")
        let newPlex = makePlexProvider(id: "new")
        let jellyfin = try makeJellyfinProvider()
        registry.reconcileAuthenticatedProvider(oldPlex, for: .plex)
        registry.reconcileAuthenticatedProvider(jellyfin, for: .jellyfin)

        registry.reconcileAuthenticatedProvider(newPlex, for: .plex)

        XCTAssertNil(registry.provider(for: oldPlex.id))
        XCTAssertNotNil(registry.provider(for: newPlex.id))
        XCTAssertNotNil(registry.provider(for: jellyfin.id))
    }

    private func makeRegistry() -> (MediaProviderRegistry, UserDefaults, String) {
        let suiteName = "MediaProviderRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (
            MediaProviderRegistry(defaults: defaults, preferredPrimaryProviderKey: "primary"),
            defaults,
            suiteName
        )
    }

    private func makePlexProvider(id: String) -> PlexProvider {
        PlexProvider(
            machineIdentifier: id,
            displayName: "Plex",
            serverURL: "https://plex.example.com",
            authToken: "plex-token"
        )
    }

    private func makeJellyfinProvider() throws -> JellyfinProvider {
        try JellyfinProvider(session: JellyfinAuthenticatedSession(
            serverURL: URL(string: "https://jellyfin.example.com")!,
            accessToken: "jellyfin-token",
            user: JellyfinUser(
                id: "user-1",
                name: "Vasilis",
                serverID: "server-a",
                primaryImageTag: nil,
                hasPassword: true
            ),
            serverID: "server-a",
            clientIdentity: JellyfinClientIdentity(
                device: "Test Apple TV",
                deviceID: "test-device",
                version: "1.0"
            ),
            authenticatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }
}
