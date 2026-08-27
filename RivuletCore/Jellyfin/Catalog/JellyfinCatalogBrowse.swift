// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A native Jellyfin catalog surface shared by iPhone, iPad, Mac and tvOS.
/// Keeping filter semantics below the UI prevents each Apple client from
/// constructing subtly different `/Items` queries.
enum JellyfinCatalogKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case movies
    case shows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: "Movies"
        case .shows: "TV Shows"
        }
    }

    var includeItemTypes: String {
        switch self {
        case .movies: "Movie"
        case .shows: "Series"
        }
    }
}

enum JellyfinCatalogFilter: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case all
    case favorites
    case watchlist
    case unwatched
    case upcoming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .watchlist: "Watchlist"
        case .unwatched: "Unwatched"
        case .upcoming: "Upcoming"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favorites: "heart.fill"
        case .watchlist: "bookmark.fill"
        case .unwatched: "circle"
        case .upcoming: "calendar.badge.clock"
        }
    }
}

struct JellyfinCatalogQuery: Codable, Hashable, Sendable {
    let kind: JellyfinCatalogKind
    var libraryID: String?
    var genre: String?
    /// Jellyfin studio names used by editorial Home shelves. The API treats
    /// multiple values as alternatives, so one rail can cover a studio's
    /// historical naming variants without a client-side full-catalog scan.
    var studios: [String]
    var filter: JellyfinCatalogFilter
    var sort: SortOption

    init(
        kind: JellyfinCatalogKind,
        libraryID: String? = nil,
        genre: String? = nil,
        studios: [String] = [],
        filter: JellyfinCatalogFilter = .all,
        sort: SortOption = .addedAtDesc
    ) {
        self.kind = kind
        self.libraryID = libraryID
        self.genre = genre
        self.studios = studios
        self.filter = filter
        self.sort = sort
    }
}

struct JellyfinCatalogGenre: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
}

extension JellyfinCatalogGenre {
    /// The intentionally small taxonomy used by the native catalog controls.
    /// Metadata agents often emit languages, countries and marketing labels as
    /// genres (for example "Korean"). Those values remain on the title, but do
    /// not become top-level navigation choices.
    static let standardOrder = [
        "Action", "Adventure", "Animation", "Comedy", "Crime",
        "Documentary", "Drama", "Family", "Fantasy", "History",
        "Horror", "Music", "Mystery", "Romance", "Science Fiction",
        "Thriller", "War", "Western"
    ]

    static func standardOnly(_ values: [JellyfinCatalogGenre]) -> [JellyfinCatalogGenre] {
        let aliases: [String: String] = [
            "sci fi": "Science Fiction", "sci-fi": "Science Fiction",
            "science-fiction": "Science Fiction", "historical": "History",
            "kids": "Family", "children": "Family"
        ]
        var byCanonical: [String: JellyfinCatalogGenre] = [:]
        for value in values {
            let raw = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = raw.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let canonical = aliases[folded.lowercased()] ?? standardOrder.first {
                $0.localizedCaseInsensitiveCompare(raw) == .orderedSame
            }
            guard let canonical, byCanonical[canonical] == nil else { continue }
            // Preserve the exact server spelling in the query while presenting
            // the canonical label in navigation.
            byCanonical[canonical] = JellyfinCatalogGenre(id: value.id, name: raw)
        }
        return standardOrder.compactMap { byCanonical[$0] }
    }
}
