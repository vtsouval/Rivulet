// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Server-scoped identity used at every Jellyfin catalog mapping boundary.
/// The server's DTO cannot override it, so equal native item IDs from two
/// servers remain distinct in navigation, focus memory, and caches.
nonisolated struct JellyfinCatalogContext: Hashable, Sendable {
    let serverID: String
    let imageBuilder: JellyfinImageURLBuilder

    var providerID: String { "jellyfin:\(serverID)" }

    init?(serverID: String, imageBuilder: JellyfinImageURLBuilder) {
        let normalized = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        self.serverID = normalized
        self.imageBuilder = imageBuilder
    }

    func ref(for itemID: String?) -> MediaItemRef? {
        guard let itemID else { return nil }
        let normalized = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return MediaItemRef(providerID: providerID, itemID: normalized)
    }
}

nonisolated enum JellyfinCatalogMapper {
    private static let ticksPerSecond: Double = 10_000_000

    // MARK: - Library

    static func library(_ view: JellyfinBaseItemDTO, context: JellyfinCatalogContext) -> MediaLibrary? {
        guard let id = normalized(view.id) else { return nil }
        return MediaLibrary(
            id: id,
            providerID: context.providerID,
            title: normalized(view.name) ?? "",
            kind: libraryKind(view.collectionType)
        )
    }

    static func libraryKind(_ collectionType: String?) -> MediaLibrary.LibraryKind {
        switch collectionType?.lowercased() {
        case "movies": return .movies
        case "tvshows": return .shows
        case "music": return .music
        case "photos": return .photos
        case "livetv": return .liveTV
        default: return .mixed
        }
    }

    // MARK: - Item

    static func kind(_ type: String?) -> MediaKind {
        switch type?.lowercased() {
        case "movie": return .movie
        case "series": return .show
        case "season": return .season
        case "episode": return .episode
        case "boxset": return .collection
        case "person": return .person
        default: return .unknown
        }
    }

    static func item(_ dto: JellyfinBaseItemDTO, context: JellyfinCatalogContext) -> MediaItem? {
        guard let ref = context.ref(for: dto.id) else { return nil }
        let itemKind = kind(dto.type)
        let parentID: String? = {
            switch itemKind {
            case .episode: return dto.seasonID ?? dto.parentID
            default: return dto.parentID
            }
        }()
        let grandparentID = itemKind == .episode ? dto.seriesID : nil

        return MediaItem(
            ref: ref,
            kind: itemKind,
            title: normalized(dto.name) ?? normalized(dto.originalTitle) ?? "",
            sortTitle: normalized(dto.sortName),
            overview: normalized(dto.overview),
            year: dto.productionYear,
            releaseDate: normalized(dto.premiereDate),
            contentRating: normalized(dto.officialRating),
            runtime: seconds(fromTicks: dto.runTimeTicks),
            genres: normalizedValues(dto.genres),
            tags: normalizedValues(dto.tags),
            isMusic: dto.mediaType?.caseInsensitiveCompare("Audio") == .orderedSame,
            parentRef: context.ref(for: parentID),
            grandparentRef: context.ref(for: grandparentID),
            episodeNumber: itemKind == .episode ? dto.indexNumber : nil,
            seasonNumber: seasonNumber(for: dto, kind: itemKind),
            childProgress: childProgress(dto),
            userState: userState(dto.userData),
            artwork: artwork(dto, context: context),
            parentArtwork: parentArtwork(dto, context: context),
            grandparentArtwork: grandparentArtwork(dto, context: context),
            seriesTitle: normalized(dto.seriesName),
            seasonTitle: normalized(dto.seasonName)
        )
    }

    static func pagedItems(
        _ response: JellyfinItemQueryResultDTO,
        requestedPage: Page,
        context: JellyfinCatalogContext
    ) -> PagedResult<MediaItem> {
        let continuation = response.continuation(for: requestedPage)
        return PagedResult(
            items: response.items.compactMap { item($0, context: context) },
            total: continuation.totalRecordCount,
            nextPage: continuation.nextPage
        )
    }

    static func userState(_ data: JellyfinUserDataDTO?) -> MediaUserState {
        MediaUserState(
            isPlayed: data?.isPlayed ?? false,
            viewOffset: seconds(fromTicks: data?.playbackPositionTicks) ?? 0,
            isFavorite: data?.isFavorite ?? false,
            lastViewedAt: JellyfinCatalogDateParser.date(from: data?.lastPlayedDate)
        )
    }

    // MARK: - Detail

    static func detail(
        _ dto: JellyfinBaseItemDTO,
        nextEpisode: JellyfinBaseItemDTO? = nil,
        context: JellyfinCatalogContext
    ) -> MediaItemDetail? {
        guard let mappedItem = item(dto, context: context) else { return nil }
        let people = dto.people ?? []
        let backdrop = mappedItem.artwork.backdrop
        let tmdbID = providerID(named: "tmdb", in: dto.providerIDs).flatMap(Int.init)

        func mapPerson(_ person: JellyfinPersonDTO, includeRole: Bool) -> MediaPerson {
            let personID = normalized(person.id)
            let name = normalized(person.name) ?? ""
            let fallbackID = "person:\((person.type ?? "unknown").lowercased()):\(name.lowercased())"
            return MediaPerson(
                id: personID ?? fallbackID,
                name: name,
                role: includeRole ? normalized(person.role) : nil,
                imageURL: personID.flatMap {
                    context.imageBuilder.url(for: JellyfinImageReferenceDTO(
                        itemID: $0,
                        type: .primary,
                        tag: normalized(person.primaryImageTag)
                    ))
                },
                originActorId: personID,
                titleTmdbId: tmdbID,
                titleIsMovie: mappedItem.kind == .movie,
                backdropURL: backdrop
            )
        }

        let cast = people
            .filter { ["actor", "gueststar"].contains($0.type?.lowercased() ?? "") }
            .map { mapPerson($0, includeRole: true) }
        let directors = people
            .filter { $0.type?.caseInsensitiveCompare("Director") == .orderedSame }
            .map { mapPerson($0, includeRole: false) }
        let writers = people
            .filter { ["writer", "screenwriter"].contains($0.type?.lowercased() ?? "") }
            .map { mapPerson($0, includeRole: false) }

        return MediaItemDetail(
            item: mappedItem,
            tagline: firstNonempty(dto.taglines),
            genres: normalizedValues(dto.genres),
            studios: normalizedValues(dto.studios?.compactMap(\.name)),
            cast: cast,
            directors: directors,
            writers: writers,
            chapters: chapters(dto, context: context),
            mediaSources: [],
            trailerURL: firstWebURL(dto.remoteTrailers),
            contentRating: normalized(dto.officialRating),
            regionOfOrigin: firstNonempty(dto.productionLocations),
            rating: dto.communityRating.map { min(10, max(0, $0)) },
            nextEpisode: nextEpisode.flatMap { item($0, context: context) },
            collections: []
        )
    }

    // MARK: - Artwork

    static func artwork(_ dto: JellyfinBaseItemDTO, context: JellyfinCatalogContext) -> MediaArtwork {
        guard let itemID = normalized(dto.id) else {
            return MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil)
        }
        let images = dto.imageTags
        let primary = reference(itemID: itemID, type: .primary, tag: images?.tag(for: .primary))
        let thumb = reference(itemID: itemID, type: .thumb, tag: images?.tag(for: .thumb)) ?? primary
        let backdrop = reference(
            itemID: itemID,
            type: .backdrop,
            tag: firstNonempty(dto.backdropImageTags),
            index: 0
        )
        let logo = reference(itemID: itemID, type: .logo, tag: images?.tag(for: .logo))
        return MediaArtwork(
            poster: context.imageBuilder.url(for: primary),
            backdrop: context.imageBuilder.url(for: backdrop),
            thumbnail: context.imageBuilder.url(for: thumb),
            logo: context.imageBuilder.url(for: logo)
        )
    }

    private static func parentArtwork(
        _ dto: JellyfinBaseItemDTO,
        context: JellyfinCatalogContext
    ) -> MediaArtwork? {
        let parentID = normalized(dto.parentPrimaryImageItemID)
            ?? normalized(dto.seasonID)
            ?? normalized(dto.parentID)
        guard let parentID else { return nil }

        let primary = reference(itemID: parentID, type: .primary, tag: dto.parentPrimaryImageTag)
        let thumbID = normalized(dto.parentThumbItemID) ?? parentID
        let thumb = reference(itemID: thumbID, type: .thumb, tag: dto.parentThumbImageTag) ?? primary
        let backdropID = normalized(dto.parentBackdropItemID) ?? parentID
        let backdrop = reference(
            itemID: backdropID,
            type: .backdrop,
            tag: firstNonempty(dto.parentBackdropImageTags),
            index: 0
        )
        let logoID = normalized(dto.parentLogoItemID) ?? parentID
        let logo = reference(itemID: logoID, type: .logo, tag: dto.parentLogoImageTag)

        guard primary != nil || thumb != nil || backdrop != nil || logo != nil else { return nil }
        return MediaArtwork(
            poster: context.imageBuilder.url(for: primary),
            backdrop: context.imageBuilder.url(for: backdrop),
            thumbnail: context.imageBuilder.url(for: thumb),
            logo: context.imageBuilder.url(for: logo)
        )
    }

    private static func grandparentArtwork(
        _ dto: JellyfinBaseItemDTO,
        context: JellyfinCatalogContext
    ) -> MediaArtwork? {
        guard let seriesID = normalized(dto.seriesID) else { return nil }
        let primary = reference(itemID: seriesID, type: .primary, tag: dto.seriesPrimaryImageTag)
        let thumb = reference(itemID: seriesID, type: .thumb, tag: dto.seriesThumbImageTag) ?? primary
        let backdropID = normalized(dto.parentBackdropItemID) ?? seriesID
        let backdrop = reference(
            itemID: backdropID,
            type: .backdrop,
            tag: firstNonempty(dto.parentBackdropImageTags),
            index: 0
        )
        let logoID = normalized(dto.parentLogoItemID) ?? seriesID
        let logo = reference(itemID: logoID, type: .logo, tag: dto.parentLogoImageTag)

        guard primary != nil || thumb != nil || backdrop != nil || logo != nil else { return nil }
        return MediaArtwork(
            poster: context.imageBuilder.url(for: primary),
            backdrop: context.imageBuilder.url(for: backdrop),
            thumbnail: context.imageBuilder.url(for: thumb),
            logo: context.imageBuilder.url(for: logo)
        )
    }

    private static func reference(
        itemID: String,
        type: JellyfinImageType,
        tag: String?,
        index: Int? = nil
    ) -> JellyfinImageReferenceDTO? {
        guard let tag = normalized(tag) else { return nil }
        return JellyfinImageReferenceDTO(itemID: itemID, type: type, tag: tag, index: index)
    }

    // MARK: - Helpers

    private static func chapters(
        _ dto: JellyfinBaseItemDTO,
        context: JellyfinCatalogContext
    ) -> [MediaChapter] {
        guard let itemID = normalized(dto.id) else { return [] }
        let source = (dto.chapters ?? []).enumerated().compactMap { index, chapter -> (Int, JellyfinChapterDTO, TimeInterval)? in
            guard let start = seconds(fromTicks: chapter.startPositionTicks) else { return nil }
            return (index, chapter, start)
        }
        return source.enumerated().map { position, value in
            let (imageIndex, chapter, start) = value
            let end = source.indices.contains(position + 1)
                ? source[position + 1].2
                : seconds(fromTicks: dto.runTimeTicks)
            let image = normalized(chapter.imageTag).map {
                JellyfinImageReferenceDTO(itemID: itemID, type: .chapter, tag: $0, index: imageIndex)
            }
            return MediaChapter(
                id: "\(itemID):chapter:\(imageIndex)",
                title: normalized(chapter.name),
                start: start,
                end: end,
                thumbnailURL: context.imageBuilder.url(for: image)
            )
        }
    }

    private static func seasonNumber(for dto: JellyfinBaseItemDTO, kind: MediaKind) -> Int? {
        switch kind {
        case .episode: return dto.parentIndexNumber
        case .season: return dto.indexNumber
        default: return nil
        }
    }

    private static func childProgress(_ dto: JellyfinBaseItemDTO) -> ChildProgress? {
        guard let total = dto.recursiveItemCount ?? dto.childCount, total > 0 else { return nil }
        if dto.userData?.isPlayed == true {
            return ChildProgress(played: total, total: total)
        }
        guard let unplayed = dto.userData?.unplayedItemCount else { return nil }
        return ChildProgress(played: max(0, min(total, total - unplayed)), total: total)
    }

    private static func seconds(fromTicks ticks: Int64?) -> TimeInterval? {
        guard let ticks, ticks >= 0 else { return nil }
        return TimeInterval(ticks) / ticksPerSecond
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedValues(_ values: [String]?) -> [String] {
        (values ?? []).compactMap(normalized)
    }

    private static func firstNonempty(_ values: [String]?) -> String? {
        (values ?? []).compactMap(normalized).first
    }

    private static func providerID(named name: String, in values: [String: String]?) -> String? {
        values?.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })
            .flatMap { normalized($0.value) }
    }

    private static func firstWebURL(_ values: [JellyfinNamedURLDTO]?) -> URL? {
        for value in values ?? [] {
            guard let raw = normalized(value.url),
                  let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }
}

private enum JellyfinCatalogDateParser {
    static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? fractional.parse(value) { return date }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}
