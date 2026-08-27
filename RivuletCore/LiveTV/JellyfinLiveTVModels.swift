// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Live TV fields are intentionally decoded separately from the catalog DTO.
/// Jellyfin's channel/program endpoints add schedule-specific properties, and
/// keeping them here prevents catalog decoding from becoming coupled to EPG.
nonisolated struct JellyfinLiveTVItemDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let type: String?
    let mediaType: String?
    let channelID: String?
    let channelNumber: String?
    let channelType: String?
    let episodeTitle: String?
    let overview: String?
    let startDate: String?
    let endDate: String?
    let genres: [String]
    let tags: [String]
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let isRepeat: Bool?
    let imageTags: JellyfinImageTagsDTO?
    let backdropImageTags: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case mediaType = "MediaType"
        case channelID = "ChannelId"
        case channelNumber = "ChannelNumber"
        case channelType = "ChannelType"
        case episodeTitle = "EpisodeTitle"
        case overview = "Overview"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case genres = "Genres"
        case tags = "Tags"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case isRepeat = "IsRepeat"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        mediaType = try values.decodeIfPresent(String.self, forKey: .mediaType)
        channelID = try values.decodeIfPresent(String.self, forKey: .channelID)
        channelNumber = try values.decodeIfPresent(String.self, forKey: .channelNumber)
        channelType = try values.decodeIfPresent(String.self, forKey: .channelType)
        episodeTitle = try values.decodeIfPresent(String.self, forKey: .episodeTitle)
        overview = try values.decodeIfPresent(String.self, forKey: .overview)
        startDate = try values.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try values.decodeIfPresent(String.self, forKey: .endDate)
        genres = try values.decodeIfPresent([String].self, forKey: .genres) ?? []
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        indexNumber = try values.decodeIfPresent(Int.self, forKey: .indexNumber)
        parentIndexNumber = try values.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        isRepeat = try values.decodeIfPresent(Bool.self, forKey: .isRepeat)
        imageTags = try values.decodeIfPresent(JellyfinImageTagsDTO.self, forKey: .imageTags)
        backdropImageTags = try values.decodeIfPresent([String].self, forKey: .backdropImageTags) ?? []
    }
}

nonisolated struct JellyfinLiveTVQueryResultDTO: Decodable, Sendable {
    let items: [JellyfinLiveTVItemDTO]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([JellyfinLiveTVItemDTO].self, forKey: .items) ?? []
        totalRecordCount = try values.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }
}

nonisolated enum JellyfinLiveTVMapper {
    static func channel(
        _ item: JellyfinLiveTVItemDTO,
        sourceID: String,
        imageBuilder: JellyfinImageURLBuilder
    ) -> UnifiedChannel? {
        guard let itemID = nonEmpty(item.id), let name = nonEmpty(item.name) else { return nil }
        let tag = item.imageTags?.tag(for: .primary)
        let logo = imageBuilder.url(
            for: JellyfinImageReferenceDTO(itemID: itemID, type: .primary, tag: tag),
            maxWidth: 600,
            quality: 92
        )
        // Preserve every server tag. Dispatcharr/Jellyfin lineups commonly put
        // the country after a genre tag; retaining only the first tag caused
        // valid regional channels to disappear behind the wrong iOS filter.
        let group = item.tags.isEmpty
            ? (item.channelType ?? "Jellyfin")
            : item.tags.joined(separator: " · ")
        let qualityLabels = ([name] + [item.channelType].compactMap { $0 } + item.tags)
            .joined(separator: " ")
            .lowercased()

        return UnifiedChannel(
            id: UnifiedChannel.makeId(sourceType: .jellyfin, sourceId: sourceID, channelId: itemID),
            sourceType: .jellyfin,
            sourceId: sourceID,
            channelNumber: channelNumber(item.channelNumber),
            name: name,
            callSign: nil,
            logoURL: logo,
            streamURL: nil,
            tvgId: itemID,
            groupTitle: group,
            isHD: qualityLabels.contains(" hd") || qualityLabels.hasSuffix("hd")
        )
    }

    static func program(
        _ item: JellyfinLiveTVItemDTO,
        unifiedChannelID: String,
        imageBuilder: JellyfinImageURLBuilder
    ) -> UnifiedProgram? {
        guard let title = nonEmpty(item.name),
              let start = date(item.startDate),
              let end = date(item.endDate),
              end > start else { return nil }

        let itemID = nonEmpty(item.id)
        let primary = itemID.map {
            JellyfinImageReferenceDTO(
                itemID: $0,
                type: .primary,
                tag: item.imageTags?.tag(for: .primary)
            )
        }
        let thumb = itemID.map {
            JellyfinImageReferenceDTO(
                itemID: $0,
                type: .thumb,
                tag: item.imageTags?.tag(for: .thumb)
            )
        }
        let backdrop = itemID.map {
            JellyfinImageReferenceDTO(
                itemID: $0,
                type: .backdrop,
                tag: item.backdropImageTags.first,
                index: item.backdropImageTags.isEmpty ? nil : 0
            )
        }

        return UnifiedProgram(
            id: itemID ?? "\(unifiedChannelID):\(Int(start.timeIntervalSince1970))",
            channelId: unifiedChannelID,
            title: title,
            subtitle: nonEmpty(item.episodeTitle),
            description: nonEmpty(item.overview),
            startTime: start,
            endTime: end,
            category: item.genres.first ?? item.tags.first,
            iconURL: imageBuilder.url(for: thumb ?? primary, maxWidth: 900, quality: 90),
            posterURL: imageBuilder.url(for: primary, maxWidth: 720, quality: 90),
            landscapeURL: imageBuilder.url(for: backdrop ?? thumb, maxWidth: 1_600, quality: 90),
            episodeNumber: episodeNumber(item),
            isNew: item.isRepeat == false
        )
    }

    static func date(_ value: String?) -> Date? {
        guard let value = nonEmpty(value) else { return nil }
        if let result = try? Date(value, strategy: .iso8601) { return result }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func channelNumber(_ value: String?) -> Int? {
        guard let value = nonEmpty(value) else { return nil }
        if let number = Int(value) { return number }
        return Int(value.split(separator: ".").first ?? "")
    }

    private static func episodeNumber(_ item: JellyfinLiveTVItemDTO) -> String? {
        switch (item.parentIndexNumber, item.indexNumber) {
        case let (.some(season), .some(episode)):
            return String(format: "S%02dE%02d", season, episode)
        case let (_, .some(episode)):
            return "E\(episode)"
        default:
            return nil
        }
    }
}
