// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum JellyfinPlaybackQuality: String, CaseIterable, Identifiable, Sendable {
    case auto
    case ultraHD = "2160"
    case fullHD = "1080"
    case hd = "720"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .ultraHD: return "4K"
        case .fullHD: return "1080p"
        case .hd: return "720p"
        }
    }
    var preferredHeight: Int? { self == .auto ? nil : Int(rawValue) }
}

nonisolated enum JellyfinPlaybackPreferences {
    static let qualityKey = "jellyfin.preferredQuality"

    static func sourceSelectionPolicy(
        preferredSourceID: String? = nil
    ) -> JellyfinSourceSelectionPolicy {
        let stored = UserDefaults.standard.string(forKey: qualityKey) ?? JellyfinPlaybackQuality.auto.rawValue
        let quality = JellyfinPlaybackQuality(rawValue: stored) ?? .auto
        return JellyfinSourceSelectionPolicy(
            preferredSourceID: preferredSourceID,
            preferredVideoHeight: quality.preferredHeight
        )
    }
}
