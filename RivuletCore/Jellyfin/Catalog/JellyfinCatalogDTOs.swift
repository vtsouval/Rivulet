// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The subset of Jellyfin's `BaseItemDto` needed at the catalog boundary.
///
/// All discriminator values remain strings. Jellyfin plugins and newer server
/// versions can add enum cases, and an unknown value must not make an entire
/// shelf fail to decode.
nonisolated struct JellyfinBaseItemDTO: Decodable, Hashable, Sendable {
    let id: String?
    let serverID: String?
    let name: String?
    let originalTitle: String?
    let sortName: String?
    let type: String?
    let mediaType: String?
    let collectionType: String?
    let overview: String?
    let productionYear: Int?
    let premiereDate: String?
    let dateCreated: String?
    let officialRating: String?
    let communityRating: Double?
    let runTimeTicks: Int64?

    let parentID: String?
    let seriesID: String?
    let seriesName: String?
    let seasonID: String?
    let seasonName: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let childCount: Int?
    let recursiveItemCount: Int?

    let genres: [String]?
    let studios: [JellyfinNameIDPairDTO]?
    let taglines: [String]?
    let tags: [String]?
    let productionLocations: [String]?
    let providerIDs: [String: String]?
    let people: [JellyfinPersonDTO]?
    let chapters: [JellyfinChapterDTO]?
    let remoteTrailers: [JellyfinNamedURLDTO]?

    let imageTags: JellyfinImageTagsDTO?
    let backdropImageTags: [String]?
    let parentPrimaryImageItemID: String?
    let parentPrimaryImageTag: String?
    let parentThumbItemID: String?
    let parentThumbImageTag: String?
    let parentBackdropItemID: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemID: String?
    let parentLogoImageTag: String?
    let seriesPrimaryImageTag: String?
    let seriesThumbImageTag: String?

    let userData: JellyfinUserDataDTO?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverID = "ServerId"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case sortName = "SortName"
        case type = "Type"
        case mediaType = "MediaType"
        case collectionType = "CollectionType"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case premiereDate = "PremiereDate"
        case dateCreated = "DateCreated"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case runTimeTicks = "RunTimeTicks"
        case parentID = "ParentId"
        case seriesID = "SeriesId"
        case seriesName = "SeriesName"
        case seasonID = "SeasonId"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case genres = "Genres"
        case studios = "Studios"
        case taglines = "Taglines"
        case tags = "Tags"
        case productionLocations = "ProductionLocations"
        case providerIDs = "ProviderIds"
        case people = "People"
        case chapters = "Chapters"
        case remoteTrailers = "RemoteTrailers"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentPrimaryImageItemID = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case parentThumbItemID = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemID = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case seriesThumbImageTag = "SeriesThumbImageTag"
        case userData = "UserData"
    }
}

nonisolated struct JellyfinUserDataDTO: Decodable, Hashable, Sendable {
    let isFavorite: Bool?
    let isPlayed: Bool?
    let playbackPositionTicks: Int64?
    let playedPercentage: Double?
    let unplayedItemCount: Int?
    let playCount: Int?
    let lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
        case isPlayed = "Played"
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playedPercentage = "PlayedPercentage"
        case unplayedItemCount = "UnplayedItemCount"
        case playCount = "PlayCount"
        case lastPlayedDate = "LastPlayedDate"
    }
}

/// Jellyfin returns image tags as a dynamically keyed JSON object. Keeping the
/// wrapper tolerant of null and non-string future values prevents one bad image
/// entry from discarding otherwise usable item metadata.
nonisolated struct JellyfinImageTagsDTO: Decodable, Hashable, Sendable {
    private let values: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: JellyfinDynamicCodingKey.self)
        var decoded: [String: String] = [:]
        for key in container.allKeys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                decoded[key.stringValue.lowercased()] = value
            }
        }
        values = decoded
    }

    func tag(for type: JellyfinImageType) -> String? {
        values[type.rawValue.lowercased()]
    }
}

nonisolated struct JellyfinNameIDPairDTO: Decodable, Hashable, Sendable {
    let id: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

/// `/Genres` uses the same lightweight name/id shape but wraps it in an
/// `Items` envelope. A dedicated type documents that contract and avoids
/// decoding the much larger BaseItem DTO for a two-field response.
nonisolated struct JellyfinGenreQueryResultDTO: Decodable, Hashable, Sendable {
    let items: [JellyfinNameIDPairDTO]

    enum CodingKeys: String, CodingKey { case items = "Items" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([JellyfinNameIDPairDTO].self, forKey: .items) ?? []
    }
}

nonisolated struct JellyfinPersonDTO: Decodable, Hashable, Sendable {
    let id: String?
    let name: String?
    let role: String?
    let type: String?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

nonisolated struct JellyfinChapterDTO: Decodable, Hashable, Sendable {
    let name: String?
    let startPositionTicks: Int64?
    let imageTag: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case startPositionTicks = "StartPositionTicks"
        case imageTag = "ImageTag"
    }
}

nonisolated struct JellyfinNamedURLDTO: Decodable, Hashable, Sendable {
    let name: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case url = "Url"
    }
}

/// Compact relevance-ordered result returned by Jellyfin's indexed
/// `/Search/Hints` endpoint. Search hints intentionally carry only enough
/// information to identify a result; the provider hydrates the matching IDs
/// in one lightweight request so cards retain artwork and per-user state.
nonisolated struct JellyfinSearchHintResultDTO: Decodable, Hashable, Sendable {
    let searchHints: [JellyfinSearchHintDTO]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case searchHints = "SearchHints"
        case totalRecordCount = "TotalRecordCount"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        searchHints = try values.decodeIfPresent([JellyfinSearchHintDTO].self, forKey: .searchHints) ?? []
        totalRecordCount = try values.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }
}

nonisolated struct JellyfinSearchHintDTO: Decodable, Hashable, Sendable {
    let id: String?
    let itemID: String?
    let name: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case itemID = "ItemId"
        case name = "Name"
        case type = "Type"
    }

    /// `ItemId` is retained by Jellyfin for compatibility with older clients;
    /// newer servers populate `Id`. Accept either without leaking that server
    /// version difference into the rest of the app.
    var resolvedID: String? {
        let value = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value }
        let legacy = itemID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy?.isEmpty == false ? legacy : nil
    }
}

/// Standard Jellyfin query result envelope used by `/Items`, user views,
/// seasons, episodes, search, and recommendation primitives.
nonisolated struct JellyfinItemQueryResultDTO: Decodable, Hashable, Sendable {
    let items: [JellyfinBaseItemDTO]
    let totalRecordCount: Int?
    let startIndex: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([JellyfinBaseItemDTO].self, forKey: .items) ?? []
        totalRecordCount = try values.decodeIfPresent(Int.self, forKey: .totalRecordCount)
        startIndex = try values.decodeIfPresent(Int.self, forKey: .startIndex)
    }

    func continuation(for requestedPage: Page) -> JellyfinContinuationDTO {
        let start = max(0, startIndex ?? requestedPage.offset)
        let end = start + items.count
        return JellyfinContinuationDTO(
            startIndex: start,
            returnedCount: items.count,
            totalRecordCount: max(end, totalRecordCount ?? end),
            requestedLimit: max(0, requestedPage.limit)
        )
    }
}

/// Response from the installed Liquid Recommendations plugin. IDs are kept as
/// strings because Jellyfin item identity is opaque to the client even when a
/// plugin currently serializes it as a GUID.
nonisolated struct JellyfinRecommendationResponseDTO: Decodable, Hashable, Sendable {
    let items: [JellyfinRecommendationEntryDTO]
    let title: String?
    let strategy: String?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case title = "Title"
        case strategy = "Strategy"
    }
}

nonisolated struct JellyfinRecommendationEntryDTO: Decodable, Hashable, Sendable {
    let id: String
    let score: Double?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case score = "Score"
        case reason = "Reason"
    }
}

/// Value-typed continuation metadata so providers do not reproduce pagination
/// edge cases independently.
nonisolated struct JellyfinContinuationDTO: Hashable, Sendable {
    let startIndex: Int
    let returnedCount: Int
    let totalRecordCount: Int
    let requestedLimit: Int

    var nextPage: Page? {
        guard requestedLimit > 0, returnedCount > 0 else { return nil }
        let nextOffset = startIndex + returnedCount
        guard nextOffset < totalRecordCount else { return nil }
        return Page(offset: nextOffset, limit: requestedLimit)
    }
}

nonisolated private struct JellyfinDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
