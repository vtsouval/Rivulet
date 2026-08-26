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

    @MainActor
    static func applyToLocalDefaults(_ preferences: JellyfinSynchronizedPreferences) {
        let defaults = UserDefaults.standard
        if let value = preferences.animeEnabled { defaults.set(value, forKey: "ios.showAnime") }
        if let value = preferences.trailerAutoplay ?? preferences.trailerPreviewsEnabled {
            defaults.set(value, forKey: "ios.autoplayTrailers")
        }
        if let value = preferences.trailerMuted { defaults.set(value, forKey: "ios.trailerMuted") }
        if let value = preferences.hideEpisodeSpoilers { defaults.set(value, forKey: "ios.blurEpisodeSpoilers") }
        if let value = preferences.audioLanguage { defaults.set(value, forKey: "ios.preferredAudioLanguage") }
        if let value = preferences.subtitleLanguage {
            defaults.set(value == "none" ? "off" : value, forKey: "ios.preferredSubtitleLanguage")
        }
        if let value = preferences.preferredResolution {
            let native = value == "auto" ? "auto" : value.replacingOccurrences(of: "p", with: "")
            defaults.set(native, forKey: qualityKey)
        }
    }
}

// MARK: - Cross-client preferences

/// Preferences shared by Bonfire and Liquid Media Experience. These are held
/// by Jellyfin per user, making the web, iPhone, iPad, Mac and Apple TV clients
/// converge instead of each device quietly developing different behaviour.
nonisolated struct JellyfinSynchronizedPreferences: Sendable {
    var animeEnabled: Bool?
    var trailerPreviewsEnabled: Bool?
    var defaultLiveTVCountry: String?
    var preferredSportsCountry: String?
    var audioLanguage: String?
    var subtitleLanguage: String?
    var preferredResolution: String?
    var trailerAutoplay: Bool?
    var trailerMuted: Bool?
    var hideEpisodeSpoilers: Bool?
}

nonisolated struct JellyfinContentPreferencesPatch: Codable, Sendable {
    var animeEnabled: Bool? = nil
    var trailerPreviewsEnabled: Bool? = nil
    var defaultLiveTVCountry: String? = nil
    var preferredSportsCountry: String? = nil

    enum CodingKeys: String, CodingKey {
        case animeEnabled = "AnimeEnabled"
        case trailerPreviewsEnabled = "TrailerPreviewsEnabled"
        case defaultLiveTVCountry = "DefaultLiveTvCountry"
        case preferredSportsCountry = "PreferredSportsCountry"
    }
}

nonisolated struct JellyfinMediaPreferencesPatch: Codable, Sendable {
    var audioLanguage: String? = nil
    var subtitleLanguage: String? = nil
    var preferredResolution: String? = nil
    var trailerAutoplay: Bool? = nil
    var trailerMuted: Bool? = nil
    var hideEpisodeSpoilers: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case audioLanguage = "AudioLanguage"
        case subtitleLanguage = "SubtitleLanguage"
        case preferredResolution = "PreferredResolution"
        case trailerAutoplay = "TrailerAutoplay"
        case trailerMuted = "TrailerMuted"
        case hideEpisodeSpoilers = "HideEpisodeSpoilers"
    }
}

private nonisolated struct JellyfinContentPreferencesResponse: Decodable, Sendable {
    let animeEnabled: Bool?
    let trailerPreviewsEnabled: Bool?
    let defaultLiveTVCountry: String?
    let preferredSportsCountry: String?

    enum CodingKeys: String, CodingKey {
        case animeEnabled = "AnimeEnabled"
        case trailerPreviewsEnabled = "TrailerPreviewsEnabled"
        case defaultLiveTVCountry = "DefaultLiveTvCountry"
        case preferredSportsCountry = "PreferredSportsCountry"
    }
}

private nonisolated struct JellyfinMediaPreferencesResponse: Decodable, Sendable {
    let audioLanguage: String?
    let subtitleLanguage: String?
    let preferredResolution: String?
    let trailerAutoplay: Bool?
    let trailerMuted: Bool?
    let hideEpisodeSpoilers: Bool?

    enum CodingKeys: String, CodingKey {
        case audioLanguage = "AudioLanguage"
        case subtitleLanguage = "SubtitleLanguage"
        case preferredResolution = "PreferredResolution"
        case trailerAutoplay = "TrailerAutoplay"
        case trailerMuted = "TrailerMuted"
        case hideEpisodeSpoilers = "HideEpisodeSpoilers"
    }
}

extension JellyfinProvider {
    func synchronizedPreferences() async -> JellyfinSynchronizedPreferences {
        async let content: JellyfinContentPreferencesResponse? = try? await transport.get(
            "/plugins/profiles/preferences",
            token: session.accessToken
        )
        async let media: JellyfinMediaPreferencesResponse? = try? await transport.get(
            "/plugins/liquidmedia/preferences",
            token: session.accessToken
        )
        let (contentValue, mediaValue) = await (content, media)
        return JellyfinSynchronizedPreferences(
            animeEnabled: contentValue?.animeEnabled,
            trailerPreviewsEnabled: contentValue?.trailerPreviewsEnabled,
            defaultLiveTVCountry: contentValue?.defaultLiveTVCountry,
            preferredSportsCountry: contentValue?.preferredSportsCountry,
            audioLanguage: mediaValue?.audioLanguage,
            subtitleLanguage: mediaValue?.subtitleLanguage,
            preferredResolution: mediaValue?.preferredResolution,
            trailerAutoplay: mediaValue?.trailerAutoplay,
            trailerMuted: mediaValue?.trailerMuted,
            hideEpisodeSpoilers: mediaValue?.hideEpisodeSpoilers
        )
    }

    @discardableResult
    func updateContentPreferences(_ patch: JellyfinContentPreferencesPatch) async throws -> JellyfinSynchronizedPreferences {
        let _: JellyfinContentPreferencesResponse = try await transport.post(
            "/plugins/profiles/preferences",
            body: patch,
            token: session.accessToken
        )
        return await synchronizedPreferences()
    }

    @discardableResult
    func updateMediaPreferences(_ patch: JellyfinMediaPreferencesPatch) async throws -> JellyfinSynchronizedPreferences {
        let _: JellyfinMediaPreferencesResponse = try await transport.post(
            "/plugins/liquidmedia/preferences",
            body: patch,
            token: session.accessToken
        )
        return await synchronizedPreferences()
    }
}
