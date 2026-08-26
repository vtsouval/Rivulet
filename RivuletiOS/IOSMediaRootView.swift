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
    }

    private var resolvedBackend: IOSMediaBackend {
        IOSMediaBackend(rawValue: selectedBackend)
            ?? ((jellyfin.isConfigured || !plex.isConfigured) ? .jellyfin : .plex)
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
