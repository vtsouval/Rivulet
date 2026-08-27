// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

enum IOSMediaBackend: String, CaseIterable, Identifiable {
    case plex
    case jellyfin

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String { self == .plex ? "play.rectangle.on.rectangle" : "play.tv" }
}

/// Provider router for the primary iOS application. Both backends use their
/// native clients and Keychain sessions; changing this preference never copies
/// credentials between services.
struct IOSRootView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @AppStorage("ios.activeMediaBackend") private var selectedBackend = ""
    @State private var quickConnectMessage: String?
    @State private var pendingQuickConnect: JellyfinQuickConnectPayload?
    @State private var pendingDevicePairing: JellyfinDevicePairingPayload?

    var body: some View {
        Group {
            switch resolvedBackend {
            case .jellyfin:
                IOSJellyfinContainerView()
            case .plex:
                IOSPlexRootView()
            }
        }
        .task {
            guard selectedBackend.isEmpty else { return }
            selectedBackend = (jellyfin.isConfigured || !plex.isConfigured)
                ? IOSMediaBackend.jellyfin.rawValue
                : IOSMediaBackend.plex.rawValue
        }
        .onOpenURL { url in
            if let pairing = try? JellyfinDevicePairingPayload(url: url) {
                selectedBackend = IOSMediaBackend.jellyfin.rawValue
                pendingDevicePairing = pairing
                return
            }
            guard url.scheme?.lowercased() == JellyfinQuickConnectPayload.scheme else { return }
            selectedBackend = IOSMediaBackend.jellyfin.rawValue
            do {
                pendingQuickConnect = try JellyfinQuickConnectPayload(url: url)
            } catch {
                quickConnectMessage = "This Quick Connect QR code is invalid or expired."
            }
        }
        .confirmationDialog(
            "Connect this device?",
            isPresented: Binding(
                get: { pendingQuickConnect != nil },
                set: { if !$0 { pendingQuickConnect = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Connect") {
                guard let payload = pendingQuickConnect else { return }
                pendingQuickConnect = nil
                Task {
                    do {
                        try await jellyfin.authorizeQuickConnect(payload: payload)
                        quickConnectMessage = "Device connected"
                    } catch {
                        quickConnectMessage = IOSJellyfinSession.message(for: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingQuickConnect = nil }
        } message: {
            Text(quickConnectPromptMessage)
        }
        .confirmationDialog(
            "Sign in with this pairing?",
            isPresented: Binding(
                get: { pendingDevicePairing != nil },
                set: { if !$0 { pendingDevicePairing = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sign In") {
                guard let pairing = pendingDevicePairing else { return }
                pendingDevicePairing = nil
                Task {
                    do {
                        try await jellyfin.claimDevicePairing(pairing)
                        quickConnectMessage = "Signed in as \(jellyfin.userName ?? "your Jellyfin profile")"
                    } catch {
                        quickConnectMessage = IOSJellyfinSession.message(for: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDevicePairing = nil }
        } message: {
            Text(devicePairingPromptMessage)
        }
        .alert("Quick Connect", isPresented: Binding(
            get: { quickConnectMessage != nil },
            set: { if !$0 { quickConnectMessage = nil } }
        )) {
            Button("OK") { quickConnectMessage = nil }
        } message: {
            Text(quickConnectMessage ?? "")
        }
    }

    private var resolvedBackend: IOSMediaBackend {
        IOSMediaBackend(rawValue: selectedBackend)
            ?? ((jellyfin.isConfigured || !plex.isConfigured) ? .jellyfin : .plex)
    }

    private var quickConnectPromptMessage: String {
        guard let payload = pendingQuickConnect else { return "" }
        let server = payload.serverURL.host ?? payload.serverURL.absoluteString
        return "Approve code \(payload.code) for \(server)."
    }

    private var devicePairingPromptMessage: String {
        guard let pairing = pendingDevicePairing else { return "" }
        let server = pairing.serverURL.host ?? pairing.serverURL.absoluteString
        return "Consume the single-use Bonfire pairing and sign in to \(server)."
    }
}

struct IOSBackendPicker: View {
    @AppStorage("ios.activeMediaBackend") private var selectedBackend = IOSMediaBackend.plex.rawValue

    var body: some View {
        Picker("Media server", selection: $selectedBackend) {
            ForEach(IOSMediaBackend.allCases) { backend in
                Label(backend.title, systemImage: backend.icon).tag(backend.rawValue)
            }
        }
    }
}
