// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One title in a person's filmography, plus whether it exists on the user's server.
struct FilmographyEntry: Hashable, Sendable {
    let item: MediaItem        // playable (plex provider) when isOnServer, else metadata-only ("tmdb")
    let isOnServer: Bool
}

/// Fully resolved data backing the person detail page.
struct PersonDetail: Hashable, Sendable {
    let id: String             // Discover person key (role tagKey) or a synthetic fallback id
    let name: String
    let biography: String?
    let portraitURL: URL?
    let movies: [FilmographyEntry]   // server entries sorted first
    let shows: [FilmographyEntry]    // server entries sorted first
}

/// Seam the view controller depends on. The concrete Plex/Discover wiring lives behind it.
protocol PersonFilmographyProviding: Sendable {
    func load(person: MediaPerson) async throws -> PersonDetail
}
