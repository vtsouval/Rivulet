// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Native Jellyfin implementation of Rivulet's provider boundary. Gelato and
/// other server-side virtual media sources remain behind Jellyfin's stream
/// endpoint; upstream/debrid credentials are never exposed to this client.
final class JellyfinProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .jellyfin
    nonisolated let displayName: String
    private(set) var connectionState: ConnectionState = .connected

    let session: JellyfinAuthenticatedSession
    let transport: JellyfinTransport
    let catalogContext: JellyfinCatalogContext
    private let playbackPreparationCache = JellyfinPlaybackPreparationCache()

    /// Fields used while painting shelves and grids. Keep this payload small:
    /// asking Jellyfin for people, chapters and every media source for dozens
    /// of cards makes tunneled servers spend seconds serializing data that the
    /// card UI never displays.
    private static let browseFields = [
        "BackdropImageTags", "ChildCount", "DateCreated", "Genres", "Overview",
        "ParentId", "PremiereDate", "ProviderIds", "RecursiveItemCount", "SeasonName",
        "SeriesId", "SeriesName", "Taglines", "Tags"
    ].joined(separator: ",")

    /// The complete metadata set is fetched only after the user opens a title.
    private static let detailFields = [
        "BackdropImageTags", "Chapters", "ChildCount", "DateCreated", "Genres",
        "MediaSources", "Overview", "ParentId", "Path", "People", "PremiereDate",
        "ProductionLocations", "ProviderIds", "RecursiveItemCount", "RemoteTrailers",
        "SeasonName", "SeriesId", "SeriesName", "Studios", "Taglines", "Tags"
    ].joined(separator: ",")

    init(session: JellyfinAuthenticatedSession) throws {
        let transport = try JellyfinTransport(
            serverURL: session.serverURL,
            clientIdentity: session.clientIdentity
        )
        let serverID = session.serverID ?? session.user.serverID
            ?? session.serverURL.host ?? session.serverURL.absoluteString
        guard let context = JellyfinCatalogContext(
            serverID: serverID,
            imageBuilder: JellyfinImageURLBuilder(
                serverURL: transport.baseURL,
                accessToken: session.accessToken
            )
        ) else {
            throw MediaProviderError.backendSpecific(underlying: "Jellyfin server identity is missing")
        }
        self.id = context.providerID
        self.displayName = session.user.name.isEmpty ? "Jellyfin" : session.user.name
        self.session = session
        self.transport = transport
        self.catalogContext = context
    }

    // MARK: - Browse

    func libraries() async throws -> [MediaLibrary] {
        try await jellyfinCall {
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/UserViews",
                queryItems: [URLQueryItem(name: "UserId", value: session.user.id)],
                token: session.accessToken
            )
            return response.items.compactMap { JellyfinCatalogMapper.library($0, context: catalogContext) }
        }
    }

    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        try await jellyfinCall {
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "ParentId", value: library.id),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "StartIndex", value: String(max(0, page.offset))),
                URLQueryItem(name: "Limit", value: String(max(1, page.limit))),
                URLQueryItem(name: "SortBy", value: sort.queryName),
                URLQueryItem(name: "SortOrder", value: sort.queryOrder)
            ]
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: query, token: session.accessToken
            )
            return JellyfinCatalogMapper.pagedItems(response, requestedPage: page, context: catalogContext)
        }
    }

    /// Paged, filterable Jellyfin-native catalog used by the Apple clients.
    /// Unlike the legacy library call this can browse across all movie/show
    /// libraries, preserves server pagination, and keeps favorites and the
    /// Liquid Media watchlist as distinct concepts.
    func catalog(_ request: JellyfinCatalogQuery, page: Page) async throws -> PagedResult<MediaItem> {
        if request.filter == .watchlist {
            return try await watchlistCatalog(request, page: page)
        }

        return try await jellyfinCall {
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: request.kind.includeItemTypes),
                URLQueryItem(name: "StartIndex", value: String(max(0, page.offset))),
                URLQueryItem(name: "Limit", value: String(max(1, page.limit))),
                URLQueryItem(name: "SortBy", value: request.sort.queryName),
                URLQueryItem(name: "SortOrder", value: request.sort.queryOrder)
            ]
            if let libraryID = request.libraryID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !libraryID.isEmpty {
                query.append(URLQueryItem(name: "ParentId", value: libraryID))
            }
            if let genre = request.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
               !genre.isEmpty {
                query.append(URLQueryItem(name: "Genres", value: genre))
            }
            switch request.filter {
            case .favorites:
                query.append(URLQueryItem(name: "Filters", value: "IsFavorite"))
            case .unwatched:
                query.append(URLQueryItem(name: "IsPlayed", value: "false"))
            case .upcoming:
                let formatter = ISO8601DateFormatter()
                query.append(URLQueryItem(name: "MinPremiereDate", value: formatter.string(from: Date())))
                if let end = Calendar(identifier: .gregorian).date(byAdding: .year, value: 2, to: Date()) {
                    query.append(URLQueryItem(name: "MaxPremiereDate", value: formatter.string(from: end)))
                }
            case .all, .watchlist:
                break
            }

            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: query, token: session.accessToken
            )
            return JellyfinCatalogMapper.pagedItems(response, requestedPage: page, context: catalogContext)
        }
    }

    func catalogGenres(kind: JellyfinCatalogKind, libraryID: String? = nil) async throws -> [JellyfinCatalogGenre] {
        try await jellyfinCall {
            var query = [
                URLQueryItem(name: "UserId", value: session.user.id),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: kind.includeItemTypes),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ]
            if let libraryID, !libraryID.isEmpty {
                query.append(URLQueryItem(name: "ParentId", value: libraryID))
            }
            let response: JellyfinGenreQueryResultDTO = try await transport.get(
                "/Genres", queryItems: query, token: session.accessToken
            )
            var seen = Set<String>()
            return response.items.compactMap { value in
                guard let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                let identity = (value.id?.isEmpty == false ? value.id! : name.lowercased())
                guard seen.insert(identity.lowercased()).inserted else { return nil }
                return JellyfinCatalogGenre(id: identity, name: name)
            }
        }
    }

    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        try await jellyfinCall {
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "ParentId", value: itemRef.itemID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ]
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: query, token: session.accessToken
            )
            return map(response.items)
        }
    }

    func search(_ query: String) async throws -> [MediaItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return try await jellyfinCall {
            // Use Jellyfin's indexed search primitive first. A recursive
            // `/Items?SearchTerm=...` scan can stall for seconds on large
            // catalogs (especially through a tunnel) and makes rapid typing
            // feel broken even when cancellation is handled correctly.
            let hintQuery = [
                URLQueryItem(name: "UserId", value: session.user.id),
                URLQueryItem(name: "SearchTerm", value: term),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "IncludeMedia", value: "true"),
                URLQueryItem(name: "IncludePeople", value: "false"),
                URLQueryItem(name: "IncludeGenres", value: "false"),
                URLQueryItem(name: "IncludeStudios", value: "false"),
                URLQueryItem(name: "IncludeArtists", value: "false"),
                URLQueryItem(name: "Limit", value: "48")
            ]
            let hints: JellyfinSearchHintResultDTO = try await transport.get(
                "/Search/Hints", queryItems: hintQuery, token: session.accessToken
            )

            var seen = Set<String>()
            let ids = hints.searchHints.compactMap { hint -> String? in
                guard let id = hint.resolvedID,
                      JellyfinCatalogMapper.kind(hint.type) == .movie
                        || JellyfinCatalogMapper.kind(hint.type) == .show,
                      seen.insert(id.lowercased()).inserted else { return nil }
                return id
            }
            guard !ids.isEmpty else { return [] }

            // Hydrate all matches in one direct-ID request. This preserves
            // Jellyfin artwork and favorite/progress state without repeating
            // the expensive full-library search. Reorder by hint relevance,
            // since an `Ids` query is not required to retain input order.
            let itemQuery = [
                URLQueryItem(name: "UserId", value: session.user.id),
                URLQueryItem(name: "Ids", value: ids.joined(separator: ",")),
                URLQueryItem(name: "Fields", value: "BackdropImageTags,Genres,PremiereDate,Tags"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
                URLQueryItem(name: "Limit", value: String(ids.count))
            ]
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: itemQuery, token: session.accessToken
            )
            let byID = map(response.items).reduce(into: [String: MediaItem]()) {
                $0[$1.ref.itemID.lowercased()] = $1
            }
            return MediaSearchSections(ids.compactMap { byID[$0.lowercased()] }).all
        }
    }

    func collectionItems(matching collectionName: String, in library: MediaLibrary) async throws -> [MediaItem] {
        let term = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return try await jellyfinCall {
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "ParentId", value: library.id),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SearchTerm", value: term),
                URLQueryItem(name: "Limit", value: "100")
            ]
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: query, token: session.accessToken
            )
            return map(response.items)
        }
    }

    func relatedItems(for itemRef: MediaItemRef) async throws -> [MediaItem] {
        try await jellyfinCall {
            var query = commonQueryItems
            query.append(URLQueryItem(name: "Limit", value: "40"))
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items/\(itemRef.itemID)/Similar", queryItems: query, token: session.accessToken
            )
            return map(response.items)
        }
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        try await jellyfinCall {
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "IsMissing", value: "false")
            ]
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Shows/\(showRef.itemID)/Episodes", queryItems: query, token: session.accessToken
            )
            return map(response.items)
        }
    }

    // MARK: - Detail

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        try await jellyfinCall {
            let dto: JellyfinBaseItemDTO = try await transport.get(
                "/Users/\(session.user.id)/Items/\(itemRef.itemID)",
                queryItems: [URLQueryItem(name: "Fields", value: Self.detailFields)],
                token: session.accessToken
            )
            let nextEpisode = try await nextEpisodeIfNeeded(for: dto)
            guard var detail = JellyfinCatalogMapper.detail(dto, nextEpisode: nextEpisode, context: catalogContext) else {
                throw MediaProviderError.notFound
            }
            let resumePosition = detail.item.userState.viewOffset
            let playback = try? await playbackInfo(
                itemID: itemRef.itemID,
                sourceID: nil,
                startPosition: resumePosition,
                autoOpenLiveStream: false
            )
            if let playback {
                await playbackPreparationCache.store(
                    playback,
                    itemID: itemRef.itemID,
                    resumePosition: resumePosition
                )
            }
            let sources = playback?.mediaSources.compactMap { mediaSource($0) } ?? []
            detail = MediaItemDetail(
                item: detail.item,
                tagline: detail.tagline,
                genres: detail.genres,
                studios: detail.studios,
                cast: detail.cast,
                directors: detail.directors,
                writers: detail.writers,
                chapters: detail.chapters,
                mediaSources: sources,
                trailerURL: detail.trailerURL,
                contentRating: detail.contentRating,
                regionOfOrigin: detail.regionOfOrigin,
                rating: detail.rating,
                nextEpisode: detail.nextEpisode,
                collections: detail.collections,
                extras: detail.extras,
                contentAdvisory: detail.contentAdvisory
            )
            return detail
        }
    }

    // MARK: - Home

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await jellyfinCall {
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "Limit", value: String(max(1, limit))),
                URLQueryItem(name: "MediaTypes", value: "Video"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
            ]
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Users/\(session.user.id)/Items/Resume", queryItems: query, token: session.accessToken
            )
            return map(response.items)
        }
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        try await jellyfinCall {
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "Limit", value: String(max(1, limit))),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode")
            ]
            let response: [JellyfinBaseItemDTO] = try await transport.get(
                "/Users/\(session.user.id)/Items/Latest", queryItems: query, token: session.accessToken
            )
            return map(response)
        }
    }

    func hubs() async throws -> [MediaHub] {
        async let preferences = synchronizedPreferences()
        async let resumed = optionalItems { try await self.continueWatching(limit: 24) }
        async let recentMovies = optionalCatalog(JellyfinCatalogQuery(kind: .movies), limit: 30)
        async let recentShows = optionalCatalog(JellyfinCatalogQuery(kind: .shows), limit: 30)
        async let favoriteMovies = optionalCatalog(
            JellyfinCatalogQuery(kind: .movies, filter: .favorites, sort: .addedAtDesc), limit: 24
        )
        async let topMovies = optionalCatalog(
            JellyfinCatalogQuery(kind: .movies, sort: .ratingDesc), limit: 24
        )
        async let topShows = optionalCatalog(
            JellyfinCatalogQuery(kind: .shows, sort: .ratingDesc), limit: 24
        )
        async let favoriteShows = optionalCatalog(
            JellyfinCatalogQuery(kind: .shows, filter: .favorites, sort: .addedAtDesc), limit: 24
        )
        async let watchlistMovies = optionalCatalog(
            JellyfinCatalogQuery(kind: .movies, filter: .watchlist, sort: .addedAtDesc), limit: 24
        )
        async let watchlistShows = optionalCatalog(
            JellyfinCatalogQuery(kind: .shows, filter: .watchlist, sort: .addedAtDesc), limit: 24
        )
        async let upcomingMovies = optionalCatalog(
            JellyfinCatalogQuery(kind: .movies, filter: .upcoming, sort: .releaseDateDesc), limit: 24
        )
        async let upcomingShows = optionalCatalog(
            JellyfinCatalogQuery(kind: .shows, filter: .upcoming, sort: .releaseDateDesc), limit: 24
        )
        async let recommendedMovies = optionalRecommendations(itemType: "Movie", mode: "personal", limit: 24)
        async let recommendedShows = optionalRecommendations(itemType: "Series", mode: "personal", limit: 24)
        async let becauseMovies = optionalRecommendations(itemType: "Movie", mode: "because", limit: 20)

        let (
            synced, continueItems, movieItems, showItems,
            movieFavorites, ratedMovies, ratedShows, showFavorites,
            movieWatchlist, showWatchlist, upcomingMovieItems, upcomingShowItems,
            moviePicks, showPicks, because
        ) = await (
            preferences, resumed, recentMovies, recentShows,
            favoriteMovies, topMovies, topShows, favoriteShows,
            watchlistMovies, watchlistShows, upcomingMovies, upcomingShows,
            recommendedMovies, recommendedShows, becauseMovies
        )
        let showAnime = synced.animeEnabled ?? true
        func visible(_ items: [MediaItem]) -> [MediaItem] {
            showAnime ? items : items.filter { !$0.isAnime }
        }

        var result: [MediaHub] = []
        if !continueItems.isEmpty {
            result.append(MediaHub(id: "\(id):continue", providerID: id, title: "Continue Watching", style: .shelf, items: visible(continueItems)))
        }
        let personalPicks = visible(interleaved(moviePicks.items, showPicks.items)).prefix(24)
        if !personalPicks.isEmpty {
            result.append(MediaHub(id: "\(id):picks", providerID: id, title: "Top Picks for You", style: .shelf, items: Array(personalPicks)))
        }
        let becauseItems = Self.recommendationsExcludingAnchor(visible(because.items), title: because.title)
        if becauseItems.count >= 2 {
            result.append(MediaHub(id: "\(id):because", providerID: id, title: because.title ?? "Because You Watched", style: .shelf, items: becauseItems))
        }
        let editorial = visible(dailyRotated(ratedMovies, limit: 18))
        if !editorial.isEmpty {
            result.append(MediaHub(id: "\(id):directors-picks", providerID: id, title: "Director’s Picks", style: .shelf, items: editorial))
        }
        result.append(contentsOf: genreHubs(
            from: visible(interleaved(movieItems + ratedMovies, showItems + ratedShows)),
            identityPrefix: "\(id):discover",
            titleSuffix: "Movies & Shows",
            maximum: 6
        ))
        if !movieItems.isEmpty {
            result.append(MediaHub(id: "\(id):recent-movies", providerID: id, title: "New Movies", style: .shelf, items: visible(movieItems)))
        }
        if !showItems.isEmpty {
            result.append(MediaHub(id: "\(id):recent-shows", providerID: id, title: "New TV Shows", style: .shelf, items: visible(showItems)))
        }
        if !movieWatchlist.isEmpty {
            result.append(MediaHub(id: "\(id):watchlist-movies", providerID: id, title: "Movie Watchlist", style: .shelf, items: visible(movieWatchlist)))
        }
        if !showWatchlist.isEmpty {
            result.append(MediaHub(id: "\(id):watchlist-shows", providerID: id, title: "TV Watchlist", style: .shelf, items: visible(showWatchlist)))
        }
        let upcoming = visible(interleaved(upcomingMovieItems, upcomingShowItems))
        if !upcoming.isEmpty {
            result.append(MediaHub(id: "\(id):upcoming", providerID: id, title: "Coming Soon", style: .shelf, items: upcoming))
        }
        if !movieFavorites.isEmpty {
            result.append(MediaHub(id: "\(id):favorite-movies", providerID: id, title: "Favorite Movies", style: .shelf, items: visible(movieFavorites)))
        }
        if !showFavorites.isEmpty {
            result.append(MediaHub(id: "\(id):favorite-shows", providerID: id, title: "Favorite TV Shows", style: .shelf, items: visible(showFavorites)))
        }
        if !ratedShows.isEmpty {
            result.append(MediaHub(id: "\(id):top-shows", providerID: id, title: "Critically Acclaimed TV", style: .shelf, items: visible(ratedShows)))
        }
        return Self.uniqueAcrossHubs(result)
    }

    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        let catalogKind: JellyfinCatalogKind? = switch library.kind {
        case .movies: .movies
        case .shows: .shows
        default: nil
        }
        guard let catalogKind else {
            let page = try await items(in: library, sort: .addedAtDesc, page: Page(offset: 0, limit: 30))
            return page.items.isEmpty ? [] : [MediaHub(
                id: "\(id):\(library.id):recent", providerID: id,
                title: "Recently Added", style: .shelf, items: page.items
            )]
        }

        async let recent = optionalCatalog(
            JellyfinCatalogQuery(kind: catalogKind, libraryID: library.id, sort: .addedAtDesc), limit: 30
        )
        async let top = optionalCatalog(
            JellyfinCatalogQuery(kind: catalogKind, libraryID: library.id, sort: .ratingDesc), limit: 24
        )
        async let favorites = optionalCatalog(
            JellyfinCatalogQuery(kind: catalogKind, libraryID: library.id, filter: .favorites, sort: .addedAtDesc), limit: 24
        )
        async let watchlist = optionalCatalog(
            JellyfinCatalogQuery(kind: catalogKind, libraryID: library.id, filter: .watchlist, sort: .addedAtDesc), limit: 24
        )
        async let upcoming = optionalCatalog(
            JellyfinCatalogQuery(kind: catalogKind, libraryID: library.id, filter: .upcoming, sort: .releaseDateDesc), limit: 24
        )
        async let recommendations = optionalRecommendations(
            itemType: catalogKind == .movies ? "Movie" : "Series", mode: "personal", limit: 24
        )
        let (recentItems, topItems, favoriteItems, watchlistItems, upcomingItems, picks) = await (
            recent, top, favorites, watchlist, upcoming, recommendations
        )
        var result = [
            MediaHub(id: "\(id):\(library.id):picks", providerID: id, title: "Top Picks for You", style: .shelf, items: picks.items),
        ]
        result.append(contentsOf: genreHubs(
            from: recentItems + topItems,
            identityPrefix: "\(id):\(library.id):genre",
            titleSuffix: catalogKind == .movies ? "Movies" : "TV Shows",
            maximum: 6
        ))
        result += [
            MediaHub(id: "\(id):\(library.id):recent", providerID: id, title: "Recently Added", style: .shelf, items: recentItems),
            MediaHub(id: "\(id):\(library.id):top", providerID: id, title: "Popular Now", style: .shelf, items: topItems),
            MediaHub(id: "\(id):\(library.id):watchlist", providerID: id, title: "Watchlist", style: .shelf, items: watchlistItems),
            MediaHub(id: "\(id):\(library.id):favorites", providerID: id, title: "Favorites", style: .shelf, items: favoriteItems),
            MediaHub(id: "\(id):\(library.id):upcoming", providerID: id, title: "Coming Soon", style: .shelf, items: upcomingItems)
        ]
        return Self.uniqueAcrossHubs(result.filter { !$0.items.isEmpty })
    }

    // MARK: - Playback

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo {
        try await jellyfinCall {
            let capabilities = Self.playbackCapabilities
            let prepared = sourceID == nil
                ? await playbackPreparationCache.take(itemID: itemRef.itemID)
                : nil
            let cachedResumePosition = prepared == nil
                ? await playbackPreparationCache.takeResumePosition(itemID: itemRef.itemID)
                : nil
            let resumePosition = prepared?.resumePosition ?? cachedResumePosition

            var selectedAudio = storedTrackIndex(kind: "audio", itemRef: itemRef, sourceID: sourceID)
            var selectedSubtitle = storedTrackIndex(kind: "subtitle", itemRef: itemRef, sourceID: sourceID)
            var response: JellyfinPlaybackInfoResponse
            if let prepared {
                response = prepared.response
            } else {
                response = try await playbackInfo(
                    itemID: itemRef.itemID,
                    sourceID: sourceID,
                    startPosition: resumePosition,
                    audioStreamIndex: selectedAudio,
                    subtitleStreamIndex: selectedSubtitle,
                    autoOpenLiveStream: true
                )
            }
            var ranked = JellyfinSourceSelector.best(
                from: response.mediaSources,
                capabilities: capabilities,
                policy: JellyfinPlaybackPreferences.sourceSelectionPolicy(
                    preferredSourceID: sourceID
                )
            )

            // A source chosen after an unscoped detail request can have its own
            // saved track preferences. Re-negotiate only when those choices or
            // a virtual/live source require Jellyfin to open the source.
            if let initial = ranked, sourceID == nil {
                selectedAudio = storedTrackIndex(
                    kind: "audio", itemRef: itemRef, sourceID: initial.source.id
                )
                selectedSubtitle = storedTrackIndex(
                    kind: "subtitle", itemRef: itemRef, sourceID: initial.source.id
                )
                let mustOpenSource = initial.source.requiresOpening == true
                    || initial.source.isGelatoVirtual
                if selectedAudio != nil || selectedSubtitle != nil || mustOpenSource {
                    response = try await playbackInfo(
                        itemID: itemRef.itemID,
                        sourceID: initial.source.id,
                        startPosition: resumePosition,
                        audioStreamIndex: selectedAudio,
                        subtitleStreamIndex: selectedSubtitle,
                        autoOpenLiveStream: true
                    )
                    ranked = JellyfinSourceSelector.best(
                        from: response.mediaSources,
                        capabilities: capabilities,
                        policy: JellyfinPlaybackPreferences.sourceSelectionPolicy(
                            preferredSourceID: initial.source.id
                        )
                    )
                }
            }

            guard let ranked,
                  let unresolved = mediaSource(
                    ranked.source,
                    selectedAudio: selectedAudio,
                    selectedSubtitle: selectedSubtitle
                  ) else {
                throw MediaProviderError.notPlayable
            }
            let request = try JellyfinPlaybackURLBuilder.playableRequest(
                serverURL: transport.baseURL,
                itemID: itemRef.itemID,
                source: ranked.source,
                delivery: ranked.delivery,
                playSessionID: response.playSessionID,
                audioStreamIndex: selectedAudio ?? ranked.source.defaultAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitle ?? ranked.source.defaultSubtitleStreamIndex,
                authorizationHeader: session.clientIdentity.authorizationHeader(token: session.accessToken)
            )
            return request.streamInfo(
                replacing: unresolved,
                playSessionID: response.playSessionID,
                trackInfoAvailable: true
            )
        }
    }

    func progressReporter(for itemRef: MediaItemRef, playSessionID: String?) -> any ProgressReporter {
        JellyfinProgressReporter(
            transport: transport,
            token: session.accessToken,
            context: JellyfinPlaybackReportContext(
                itemID: itemRef.itemID,
                playSessionID: playSessionID,
                delivery: .directPlay
            )
        )
    }

    func progressReporter(for itemRef: MediaItemRef, streamInfo: StreamInfo) -> any ProgressReporter {
        let delivery: JellyfinPlaybackDelivery
        switch streamInfo.source.streamKind {
        case .directPlay:
            delivery = .directPlay
        case .hlsTranscode, .progressiveTranscode:
            delivery = .transcode
        }
        return JellyfinProgressReporter(
            transport: transport,
            token: session.accessToken,
            context: JellyfinPlaybackReportContext(
                itemID: itemRef.itemID,
                mediaSourceID: streamInfo.source.id,
                playSessionID: streamInfo.playSessionID,
                liveStreamID: streamInfo.requiresLiveStreamClose ? streamInfo.liveStreamID : nil,
                delivery: delivery,
                audioStreamIndex: streamInfo.source.audioTracks.first(where: \.isSelected)?.index,
                subtitleStreamIndex: streamInfo.source.subtitleTracks.first(where: \.isSelected)?.index,
                canSeek: streamInfo.liveStreamID == nil
            )
        )
    }

    // Track choices are included in the next PlaybackInfo negotiation. Jellyfin
    // has no durable per-item stream-index preference, so Rivulet stores this
    // non-secret choice locally per user, item, and source.
    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {
        guard let index = Int(trackID) else { throw MediaProviderError.backendSpecific(underlying: "Invalid Jellyfin audio track") }
        UserDefaults.standard.set(index, forKey: trackKey(kind: "audio", itemRef: itemRef, sourceID: sourceID))
    }

    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {
        let index: Int
        if let trackID {
            guard let parsed = Int(trackID) else { throw MediaProviderError.backendSpecific(underlying: "Invalid Jellyfin subtitle track") }
            index = parsed
        } else {
            index = -1
        }
        UserDefaults.standard.set(index, forKey: trackKey(kind: "subtitle", itemRef: itemRef, sourceID: sourceID))
    }

    // MARK: - Watch state

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        _ = try await jellyfinCall {
            try await transport.requestEmpty(
                "/Users/\(session.user.id)/PlayedItems/\(itemRef.itemID)",
                method: .post,
                token: session.accessToken
            )
        }
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        _ = try await jellyfinCall {
            try await transport.requestEmpty(
                "/Users/\(session.user.id)/PlayedItems/\(itemRef.itemID)",
                method: .delete,
                token: session.accessToken
            )
        }
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        try await jellyfinCall {
            let context = JellyfinPlaybackReportContext(itemID: itemRef.itemID, delivery: .directPlay)
            let body = JellyfinPlaybackProgressRequest.playing(context: context, position: position)
            try await transport.requestEmpty(
                "/Sessions/Playing/Progress", method: .post, token: session.accessToken, body: body
            )
        }
    }

    // MARK: - Watchlist

    var supportsWatchlist: Bool { true }

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool {
        guard let response: JellyfinWatchlistResponse = try? await transport.get(
            "/plugins/liquidmedia/watchlist", token: session.accessToken
        ) else { return false }
        return response.itemIDs.contains { $0.caseInsensitiveCompare(ref.itemID) == .orderedSame }
    }

    func addToWatchlist(_ ref: MediaItemRef) async throws {
        try await setWatchlist(ref, enabled: true)
    }

    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        try await setWatchlist(ref, enabled: false)
    }

    /// Jellyfin favorite state is independent from the Liquid Media watchlist.
    /// Keep the two actions separate so an iOS heart never mutates watchlist.
    func setFavorite(_ ref: MediaItemRef, enabled: Bool) async throws {
        _ = try await jellyfinCall {
            try await transport.requestEmpty(
                "/Users/\(session.user.id)/FavoriteItems/\(ref.itemID)",
                method: enabled ? .post : .delete,
                token: session.accessToken
            )
        }
    }

    // MARK: - Helpers

    private var commonQueryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "UserId", value: session.user.id),
            URLQueryItem(name: "Fields", value: Self.browseFields),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "EnableUserData", value: "true")
        ]
    }

    private func map(_ values: [JellyfinBaseItemDTO]) -> [MediaItem] {
        values.compactMap { JellyfinCatalogMapper.item($0, context: catalogContext) }
    }

    private func optionalItems(_ operation: @escaping @Sendable () async throws -> [MediaItem]) async -> [MediaItem] {
        (try? await operation()) ?? []
    }

    private func optionalCatalog(_ request: JellyfinCatalogQuery, limit: Int) async -> [MediaItem] {
        (try? await catalog(request, page: Page(offset: 0, limit: limit)).items) ?? []
    }

    private func optionalRecommendations(
        itemType: String,
        mode: String,
        limit: Int
    ) async -> (title: String?, items: [MediaItem]) {
        do {
            let response: JellyfinRecommendationResponseDTO = try await transport.get(
                "/plugins/liquidrecommendations/discover",
                queryItems: [
                    URLQueryItem(name: "itemType", value: itemType),
                    URLQueryItem(name: "mode", value: mode),
                    URLQueryItem(name: "limit", value: String(max(8, limit)))
                ],
                token: session.accessToken
            )
            let ids = response.items.map(\.id)
            guard !ids.isEmpty else { return (response.title, []) }
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "Ids", value: ids.joined(separator: ",")),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: itemType),
                URLQueryItem(name: "Limit", value: String(ids.count))
            ]
            let resolved: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: query, token: session.accessToken
            )
            let byID = map(resolved.items).reduce(into: [String: MediaItem]()) {
                $0[$1.ref.itemID.lowercased()] = $1
            }
            return (response.title, ids.compactMap { byID[$0.lowercased()] })
        } catch {
            // The native clients remain fully functional when the optional
            // recommendations plugin is absent or temporarily unavailable.
            return (nil, [])
        }
    }

    private func interleaved(_ first: [MediaItem], _ second: [MediaItem]) -> [MediaItem] {
        var values: [MediaItem] = []
        for index in 0..<max(first.count, second.count) {
            if first.indices.contains(index) { values.append(first[index]) }
            if second.indices.contains(index) { values.append(second[index]) }
        }
        return values
    }

    private func dailyRotated(_ items: [MediaItem], limit: Int) -> [MediaItem] {
        guard !items.isEmpty else { return [] }
        let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: Date()) ?? 0
        let offset = day % items.count
        let rotated = Array(items[offset...]) + Array(items[..<offset])
        return Array(rotated.prefix(max(1, limit)))
    }

    /// Builds useful genre rails from cards already fetched for the page. A
    /// title is assigned to one preferred genre only, so the initial screen
    /// exposes more unique artwork without another round trip to Jellyfin.
    private func genreHubs(
        from items: [MediaItem],
        identityPrefix: String,
        titleSuffix: String,
        maximum: Int
    ) -> [MediaHub] {
        let priority = [
            "Action", "Drama", "Comedy", "Crime", "Documentary", "Family",
            "Animation", "Science Fiction", "Adventure", "Thriller", "Mystery"
        ]
        var groups: [String: [MediaItem]] = [:]
        var canonicalNames: [String: String] = [:]
        var seenItems = Set<MediaItemRef>()

        for item in items where seenItems.insert(item.ref).inserted {
            let values = item.genres ?? []
            guard !values.isEmpty else { continue }
            let genre = priority.compactMap { preferred in
                values.first { $0.localizedCaseInsensitiveCompare(preferred) == .orderedSame }
            }.first ?? values[0]
            let key = genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            canonicalNames[key] = canonicalNames[key] ?? genre
            groups[key, default: []].append(item)
        }

        let orderedKeys = groups.keys.sorted { lhs, rhs in
            let leftName = canonicalNames[lhs] ?? lhs
            let rightName = canonicalNames[rhs] ?? rhs
            let leftRank = priority.firstIndex { $0.localizedCaseInsensitiveCompare(leftName) == .orderedSame }
                ?? priority.count
            let rightRank = priority.firstIndex { $0.localizedCaseInsensitiveCompare(rightName) == .orderedSame }
                ?? priority.count
            return leftRank == rightRank ? leftName < rightName : leftRank < rightRank
        }

        return orderedKeys.compactMap { key in
            guard let values = groups[key], values.count >= 2 else { return nil }
            let name = canonicalNames[key] ?? key
            return MediaHub(
                id: "\(identityPrefix):\(key)",
                providerID: id,
                title: "\(name) \(titleSuffix)",
                style: .shelf,
                items: Array(values.prefix(24))
            )
        }.prefix(max(0, maximum)).map { $0 }
    }

    static func uniqueAcrossHubs(_ hubs: [MediaHub]) -> [MediaHub] {
        var seen = Set<String>()
        return hubs.compactMap { hub in
            let items = hub.items.filter { seen.insert(semanticIdentity(for: $0)).inserted }
            guard !items.isEmpty else { return nil }
            return MediaHub(id: hub.id, providerID: hub.providerID, title: hub.title, style: hub.style, items: items)
        }
    }

    static func recommendationsExcludingAnchor(_ items: [MediaItem], title: String?) -> [MediaItem] {
        var unique = Set<String>()
        let anchorPrefix = "becauseyouwatched"
        let normalizedHeading = normalizedIdentityText(title)
        let anchor = normalizedHeading.hasPrefix(anchorPrefix)
            ? String(normalizedHeading.dropFirst(anchorPrefix.count))
            : ""
        return items.filter { item in
            let itemTitle = normalizedIdentityText(item.title)
            guard anchor.isEmpty || itemTitle != anchor else { return false }
            return unique.insert(semanticIdentity(for: item)).inserted
        }
    }

    /// Jellyfin may expose mirrored copies of a title under different item IDs.
    /// Recommendation plugins can therefore return five technically distinct
    /// IDs that all render as the same movie. Deduplicate by what the viewer
    /// sees, while retaining separate episodes with identical titles.
    static func semanticIdentity(for item: MediaItem) -> String {
        switch item.kind {
        case .episode:
            return [
                item.kind.rawValue, normalizedIdentityText(item.seriesTitle),
                String(item.seasonNumber ?? -1), String(item.episodeNumber ?? -1),
                normalizedIdentityText(item.title)
            ].joined(separator: ":")
        case .movie, .show, .season:
            return [item.kind.rawValue, normalizedIdentityText(item.title), String(item.year ?? -1)].joined(separator: ":")
        default:
            return "\(item.kind.rawValue):\(item.ref.providerID):\(item.ref.itemID)"
        }
    }

    static func normalizedIdentityText(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func watchlistCatalog(
        _ request: JellyfinCatalogQuery,
        page: Page
    ) async throws -> PagedResult<MediaItem> {
        try await jellyfinCall {
            let response: JellyfinWatchlistResponse = try await transport.get(
                "/plugins/liquidmedia/watchlist", token: session.accessToken
            )
            let offset = min(max(0, page.offset), response.itemIDs.count)
            let end = min(response.itemIDs.count, offset + max(1, page.limit))
            let ids = Array(response.itemIDs[offset..<end])
            guard !ids.isEmpty else {
                return PagedResult(items: [], total: response.itemIDs.count, nextPage: nil)
            }
            var query = commonQueryItems
            query += [
                URLQueryItem(name: "Ids", value: ids.joined(separator: ",")),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: request.kind.includeItemTypes),
                URLQueryItem(name: "SortBy", value: request.sort.queryName),
                URLQueryItem(name: "SortOrder", value: request.sort.queryOrder),
                URLQueryItem(name: "Limit", value: String(ids.count))
            ]
            if let genre = request.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
                query.append(URLQueryItem(name: "Genres", value: genre))
            }
            let items: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: query, token: session.accessToken
            )
            let mapped = map(items.items)
            let next = end < response.itemIDs.count ? Page(offset: end, limit: page.limit) : nil
            return PagedResult(items: mapped, total: response.itemIDs.count, nextPage: next)
        }
    }

    private func nextEpisodeIfNeeded(for item: JellyfinBaseItemDTO) async throws -> JellyfinBaseItemDTO? {
        guard JellyfinCatalogMapper.kind(item.type) == .show, let seriesID = item.id else { return nil }
        var query = commonQueryItems
        query += [
            URLQueryItem(name: "SeriesId", value: seriesID),
            URLQueryItem(name: "Limit", value: "1")
        ]
        let response: JellyfinItemQueryResultDTO = try await transport.get(
            "/Shows/NextUp", queryItems: query, token: session.accessToken
        )
        return response.items.first
    }

    private func playbackInfo(
        itemID: String,
        sourceID: String?,
        startPosition: TimeInterval? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        autoOpenLiveStream: Bool
    ) async throws -> JellyfinPlaybackInfoResponse {
        let body = JellyfinPlaybackInfoRequest(
            userID: session.user.id,
            startPosition: startPosition,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            mediaSourceID: sourceID,
            autoOpenLiveStream: autoOpenLiveStream,
            capabilities: Self.playbackCapabilities
        )
        return try await transport.post(
            "/Items/\(itemID)/PlaybackInfo", body: body, token: session.accessToken
        )
    }

    private func mediaSource(
        _ value: JellyfinMediaSourceInfo,
        selectedAudio: Int? = nil,
        selectedSubtitle: Int? = nil
    ) -> MediaSource? {
        guard let sourceID = value.id, !sourceID.isEmpty else { return nil }
        let videos = value.videoStreams.map(videoTrack)
        let audios = value.audioStreams.map {
            audioTrack($0, selected: selectedAudio ?? value.defaultAudioStreamIndex)
        }
        let subtitles = value.subtitleStreams.map {
            subtitleTrack($0, selected: selectedSubtitle ?? value.defaultSubtitleStreamIndex)
        }
        return MediaSource(
            id: sourceID,
            container: value.container,
            duration: JellyfinTicks.toSeconds(value.runTimeTicks) ?? 0,
            bitrate: value.bitrate,
            fileSize: value.size,
            fileName: value.name,
            videoResolution: resolution(height: value.videoHeight),
            videoTracks: videos,
            audioTracks: audios,
            subtitleTracks: subtitles,
            streamKind: .directPlay,
            streamURL: nil
        )
    }

    private func videoTrack(_ value: JellyfinMediaStream) -> VideoTrack {
        VideoTrack(
            id: String(value.index ?? 0),
            codec: value.codec ?? "unknown",
            profile: value.profile,
            level: value.level.map(Int.init),
            width: value.width,
            height: value.height,
            frameRate: value.realFrameRate ?? value.averageFrameRate,
            bitrate: value.bitRate,
            videoRange: videoRange(value),
            isDefault: value.isDefault ?? true,
            scanType: value.isInterlaced == true ? "interlaced" : "progressive"
        )
    }

    private func audioTrack(_ value: JellyfinMediaStream, selected: Int?) -> AudioTrack {
        let index = value.index ?? 0
        return AudioTrack(
            id: String(index),
            index: index,
            codec: value.codec ?? "unknown",
            profile: value.profile,
            channels: value.channels,
            channelLayout: value.channelLayout,
            language: value.language,
            title: value.title,
            extendedTitle: value.displayTitle,
            bitrate: value.bitRate,
            samplingRate: value.sampleRate,
            isDefault: value.isDefault ?? false,
            isForced: value.isForced ?? false,
            isSelected: index == selected
        )
    }

    private func subtitleTrack(_ value: JellyfinMediaStream, selected: Int?) -> SubtitleTrack {
        let index = value.index ?? 0
        return SubtitleTrack(
            id: String(index),
            index: index,
            codec: value.codec ?? "unknown",
            language: value.language,
            title: value.title,
            extendedTitle: value.displayTitle,
            isDefault: value.isDefault ?? false,
            isForced: value.isForced ?? false,
            isHearingImpaired: value.isHearingImpaired ?? false,
            isEmbedded: !(value.isExternal ?? false),
            externalURL: nil,
            isSelected: index == selected
        )
    }

    private func videoRange(_ value: JellyfinMediaStream) -> VideoTrack.VideoRange {
        if let profile = value.dvProfile { return .dolbyVision(profile: profile) }
        if value.hdr10PlusPresent == true { return .hdr10Plus }
        let label = [value.videoRange, value.videoRangeType, value.colorTransfer]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        if label.contains("hlg") { return .hlg }
        if label.contains("hdr") || label.contains("smpte2084") { return .hdr10 }
        return .sdr
    }

    private func resolution(height: Int?) -> String? {
        guard let height else { return nil }
        switch height {
        case 1_600...: return "4k"
        case 800...: return "1080"
        case 620...: return "720"
        case 500...: return "576"
        case 1...: return "480"
        default: return nil
        }
    }

    private func setWatchlist(_ ref: MediaItemRef, enabled: Bool) async throws {
        try await jellyfinCall {
            let _: JellyfinWatchlistMutationResponse = try await transport.post(
                "/plugins/liquidmedia/watchlist/\(ref.itemID)",
                body: JellyfinWatchlistMutationRequest(enabled: enabled),
                token: session.accessToken
            )
        }
    }

    private func trackKey(kind: String, itemRef: MediaItemRef, sourceID: String?) -> String {
        "jellyfin.track.\(id).\(session.user.id).\(kind).\(itemRef.itemID).\(sourceID ?? "default")"
    }

    private func storedTrackIndex(kind: String, itemRef: MediaItemRef, sourceID: String?) -> Int? {
        UserDefaults.standard.object(
            forKey: trackKey(kind: kind, itemRef: itemRef, sourceID: sourceID)
        ) as? Int
    }

    #if targetEnvironment(macCatalyst)
    /// Catalyst uses AVPlayer because the AetherEngine FFmpeg binaries do not
    /// ship Catalyst slices. Ask Jellyfin for its Apple-compatible HLS route
    /// rather than handing AVPlayer an arbitrary direct-play container.
    private static let playbackCapabilities = JellyfinPlaybackCapabilities(
        allowsDirectPlay: false,
        allowsRemux: true,
        allowsTranscoding: true,
        allowsVideoStreamCopy: true,
        allowsAudioStreamCopy: true,
        maxStreamingBitrate: 80_000_000,
        maxVideoWidth: 3_840,
        maxVideoHeight: 2_160,
        maxAudioChannels: 8
    )
    #else
    private static let playbackCapabilities = JellyfinPlaybackCapabilities(
        allowsDirectPlay: true,
        allowsRemux: true,
        allowsTranscoding: true,
        allowsVideoStreamCopy: true,
        allowsAudioStreamCopy: true,
        maxStreamingBitrate: 120_000_000,
        maxVideoWidth: 7_680,
        maxVideoHeight: 4_320,
        maxAudioChannels: 8
    )
    #endif
}

private extension SortOption {
    var queryName: String {
        switch self {
        case .titleAsc, .titleDesc: return "SortName"
        case .releaseDateDesc: return "PremiereDate"
        case .addedAtDesc: return "DateCreated"
        case .ratingDesc: return "CommunityRating"
        }
    }

    var queryOrder: String {
        self == .titleAsc ? "Ascending" : "Descending"
    }
}

nonisolated private struct JellyfinWatchlistResponse: Decodable, Sendable {
    let itemIDs: [String]

    enum CodingKeys: String, CodingKey { case itemIDs = "ItemIds" }
}

nonisolated private struct JellyfinWatchlistMutationRequest: Encodable, Sendable {
    let enabled: Bool
    enum CodingKeys: String, CodingKey { case enabled = "Enabled" }
}

nonisolated private struct JellyfinWatchlistMutationResponse: Decodable, Sendable {
    let itemID: String
    let enabled: Bool
    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case enabled = "Enabled"
    }
}
