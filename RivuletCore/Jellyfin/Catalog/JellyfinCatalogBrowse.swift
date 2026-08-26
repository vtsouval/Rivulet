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
    var filter: JellyfinCatalogFilter
    var sort: SortOption

    init(
        kind: JellyfinCatalogKind,
        libraryID: String? = nil,
        genre: String? = nil,
        filter: JellyfinCatalogFilter = .all,
        sort: SortOption = .addedAtDesc
    ) {
        self.kind = kind
        self.libraryID = libraryID
        self.genre = genre
        self.filter = filter
        self.sort = sort
    }
}

struct JellyfinCatalogGenre: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
}
