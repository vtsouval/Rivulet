// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderRegistry.swift
//  Rivulet
//
//  Single source of truth for active MediaProvider instances. Providers are
//  rebuilt from the currently restored Plex and Jellyfin sessions, while an
//  explicit primary-provider choice remains stable across launches.
//

import Foundation

@Observable @MainActor
final class MediaProviderRegistry {
    static let shared = MediaProviderRegistry()

    private(set) var providers: [String: any MediaProvider] = [:]
    private(set) var preferredPrimaryProviderID: String?

    private let defaults: UserDefaults
    private let preferredPrimaryProviderKey: String

    init(
        defaults: UserDefaults = .standard,
        preferredPrimaryProviderKey: String = "mediaProvider.primaryID.v1"
    ) {
        self.defaults = defaults
        self.preferredPrimaryProviderKey = preferredPrimaryProviderKey
        preferredPrimaryProviderID = defaults.string(forKey: preferredPrimaryProviderKey)
    }

    func provider(for id: String) -> (any MediaProvider)? {
        providers[id]
    }

    func enabledProviders() -> [any MediaProvider] {
        providers.values.sorted(by: Self.providerOrder)
    }

    /// The explicit selection wins when it is currently available. Otherwise
    /// use a stable fallback (Plex first for backwards compatibility, then
    /// provider ID) instead of Dictionary iteration order.
    var primaryProvider: (any MediaProvider)? {
        if let preferredPrimaryProviderID,
           let preferred = providers[preferredPrimaryProviderID] {
            return preferred
        }
        return enabledProviders().first
    }

    var primaryProviderID: String? { primaryProvider?.id }

    /// Persists an intentional provider choice. Passing nil restores the
    /// deterministic fallback without disconnecting either backend.
    func selectPrimaryProvider(_ providerID: String?) {
        if let providerID, providers[providerID] == nil { return }
        preferredPrimaryProviderID = providerID
        if let providerID {
            defaults.set(providerID, forKey: preferredPrimaryProviderKey)
        } else {
            defaults.removeObject(forKey: preferredPrimaryProviderKey)
        }
    }

    func register(_ provider: any MediaProvider) {
        providers[provider.id] = provider
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
    }

    /// Reconciles providers from both authentication systems. A sign-out from
    /// one backend removes only that backend, so a valid Jellyfin session is
    /// never discarded by a Plex refresh (and vice versa).
    func populateFromCurrentAuth() {
        reconcilePlexProvider()
        reconcileJellyfinProvider()
    }

    private func reconcilePlexProvider() {
        let auth = PlexAuthManager.shared
        guard
            let serverURL = auth.selectedServerURL,
            let token = auth.selectedServerToken
        else {
            removeProviders(ofKind: .plex)
            return
        }
        // Prefer Plex's real machineIdentifier when the user has selected a
        // server in this session. Fall back to a deterministic hash of the
        // server URL when only a restored URL/token is available — this keeps
        // providerID stable across launches (Swift's String.hashValue is
        // randomized per process and would orphan FocusMemory / nav state).
        let machineID: String = {
            if let id = auth.selectedServer?.machineIdentifier { return id }
            return Self.stableHash(of: serverURL)
        }()
        let displayName = auth.selectedServer?.name
            ?? defaults.string(forKey: "selectedServerName")
            ?? "Plex"
        let provider = PlexProvider(
            machineIdentifier: machineID,
            displayName: displayName,
            serverURL: serverURL,
            authToken: token
        )
        reconcileAuthenticatedProvider(provider, for: .plex)
    }

    private func reconcileJellyfinProvider() {
        guard let session = JellyfinSessionStore.shared.currentSession else {
            removeProviders(ofKind: .jellyfin)
            return
        }

        do {
            let provider = try JellyfinProvider(session: session)
            reconcileAuthenticatedProvider(provider, for: .jellyfin)
            Task { @MainActor in
                JellyfinPlaybackPreferences.applyToLocalDefaults(
                    await provider.synchronizedPreferences()
                )
            }
        } catch {
            // A restored session whose server identity cannot produce a
            // provider must not leave an older Jellyfin provider reachable.
            removeProviders(ofKind: .jellyfin)
        }
    }

    /// Replaces the authenticated entry for one backend without disturbing
    /// other active backends. Internal so the sign-out isolation invariant can
    /// be exercised without mutating the process-wide authentication stores.
    func reconcileAuthenticatedProvider(
        _ provider: (any MediaProvider)?,
        for kind: MediaProviderKind
    ) {
        guard let provider else {
            removeProviders(ofKind: kind)
            return
        }
        guard provider.kind == kind else { return }
        removeProviders(ofKind: kind, except: provider.id)
        register(provider)
    }

    private func removeProviders(ofKind kind: MediaProviderKind, except retainedID: String? = nil) {
        providers = providers.filter { id, provider in
            provider.kind != kind || id == retainedID
        }
    }

    private static func providerOrder(
        _ lhs: any MediaProvider,
        _ rhs: any MediaProvider
    ) -> Bool {
        let lhsRank = providerRank(lhs.kind)
        let rhsRank = providerRank(rhs.kind)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    private static func providerRank(_ kind: MediaProviderKind) -> Int {
        switch kind {
        case .plex: 0
        case .jellyfin: 1
        }
    }

    /// Process-stable hash. Avoid `String.hashValue` (per-process randomized).
    private static func stableHash(of input: String) -> String {
        // FNV-1a 64-bit — small, deterministic, no Crypto dependency.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
