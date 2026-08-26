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
        "ParentId", "PremiereDate", "ProviderIds", "RecursiveItemCount", "SeriesId",
        "Taglines", "Tags"
    ].joined(separator: ",")

    /// The complete metadata set is fetched only after the user opens a title.
    private static let detailFields = [
        "BackdropImageTags", "Chapters", "ChildCount", "DateCreated", "Genres",
        "MediaSources", "Overview", "ParentId", "Path", "People", "PremiereDate",
        "ProductionLocations", "ProviderIds", "RecursiveItemCount", "RemoteTrailers",
        "SeriesId", "Studios", "Taglines", "Tags"
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
            var items = commonQueryItems
            items += [
                URLQueryItem(name: "SearchTerm", value: term),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
                URLQueryItem(name: "Limit", value: "60")
            ]
            let response: JellyfinItemQueryResultDTO = try await transport.get(
                "/Items", queryItems: items, token: session.accessToken
            )
            return map(response.items)
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
                URLQueryItem(name: "MediaTypes", value: "Video")
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
        async let resumed = continueWatching(limit: 24)
        async let recent = recentlyAdded(limit: 30)
        let (continueItems, recentItems) = try await (resumed, recent)
        var result: [MediaHub] = []
        if !continueItems.isEmpty {
            result.append(MediaHub(id: "\(id):continue", providerID: id, title: "Continue Watching", style: .shelf, items: continueItems))
        }
        if !recentItems.isEmpty {
            result.append(MediaHub(id: "\(id):recent", providerID: id, title: "Recently Added", style: .shelf, items: recentItems))
        }
        return result
    }

    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        let page = try await items(in: library, sort: .addedAtDesc, page: Page(offset: 0, limit: 30))
        guard !page.items.isEmpty else { return [] }
        return [MediaHub(
            id: "\(id):\(library.id):recent",
            providerID: id,
            title: "Recently Added",
            style: .shelf,
            items: page.items
        )]
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
        try await jellyfinCall {
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
