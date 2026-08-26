// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Jellyfin Live TV adapter for the same unified channel/guide pipeline used
/// by Plex, Dispatcharr, and generic M3U sources.
actor JellyfinLiveTVProvider: LiveTVProvider {
    nonisolated let sourceType: LiveTVSourceType = .jellyfin
    nonisolated let sourceId: String
    nonisolated let displayName: String
    nonisolated let serverURL: URL

    private let session: JellyfinAuthenticatedSession
    private let transport: JellyfinTransport
    private let imageBuilder: JellyfinImageURLBuilder

    private var cachedChannels: [UnifiedChannel] = []
    private var lastChannelFetch: Date?
    private var cachedEPG: [String: [UnifiedProgram]] = [:]
    private var lastEPGFetch: Date?
    private var cachedEPGRange: (start: Date, end: Date)?
    private var activePlayback: [String: JellyfinPlaybackReportContext] = [:]

    private let channelCacheDuration: TimeInterval = 5 * 60
    private let epgCacheDuration: TimeInterval = 5 * 60

    init(session: JellyfinAuthenticatedSession) throws {
        let transport = try JellyfinTransport(
            serverURL: session.serverURL,
            clientIdentity: session.clientIdentity
        )
        let serverID = session.serverID ?? session.user.serverID
            ?? transport.baseURL.host ?? transport.baseURL.absoluteString
        self.sourceId = "jellyfin:\(serverID)"
        self.displayName = session.user.name.isEmpty ? "Jellyfin Live TV" : "Jellyfin · \(session.user.name)"
        self.serverURL = transport.baseURL
        self.session = session
        self.transport = transport
        self.imageBuilder = JellyfinImageURLBuilder(
            serverURL: transport.baseURL,
            accessToken: session.accessToken
        )
    }

    var isConnected: Bool {
        get async {
            do {
                let _: JellyfinUser = try await transport.get(
                    "/Users/Me",
                    token: session.accessToken
                )
                return true
            } catch {
                return false
            }
        }
    }

    func fetchChannels() async throws -> [UnifiedChannel] {
        if let lastChannelFetch,
           Date().timeIntervalSince(lastChannelFetch) < channelCacheDuration,
           !cachedChannels.isEmpty {
            return cachedChannels
        }
        return try await refreshChannels()
    }

    func refreshChannels() async throws -> [UnifiedChannel] {
        let response: JellyfinLiveTVQueryResultDTO = try await transport.get(
            "/LiveTv/Channels",
            queryItems: [
                URLQueryItem(name: "UserId", value: session.user.id),
                URLQueryItem(name: "StartIndex", value: "0"),
                URLQueryItem(name: "Limit", value: "10000"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "Fields", value: "ChannelType,Genres,Tags")
            ],
            token: session.accessToken
        )

        let channels = response.items.compactMap {
            JellyfinLiveTVMapper.channel($0, sourceID: sourceId, imageBuilder: imageBuilder)
        }
        guard !channels.isEmpty else { throw LiveTVProviderError.noChannelsFound }
        cachedChannels = channels
        lastChannelFetch = Date()
        return channels
    }

    func fetchEPG(
        for channels: [UnifiedChannel],
        startDate: Date,
        endDate: Date
    ) async throws -> [String: [UnifiedProgram]] {
        guard !channels.isEmpty else { return [:] }
        if let lastEPGFetch,
           Date().timeIntervalSince(lastEPGFetch) < epgCacheDuration,
           let cachedEPGRange,
           cachedEPGRange.start <= startDate,
           cachedEPGRange.end >= endDate,
           !cachedEPG.isEmpty {
            return filteredEPG(cachedEPG, channels: channels, startDate: startDate, endDate: endDate)
        }

        let channelLookup = Dictionary(
            uniqueKeysWithValues: channels.compactMap { channel in
                channel.tvgId.map { ($0, channel.id) }
            }
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.string(from: startDate)
        let end = formatter.string(from: endDate)

        // Keep query strings below common reverse-proxy limits while still
        // fetching a large lineup in a handful of parallel requests.
        let chunks = channelLookup.keys.sorted().chunked(maxCount: 80)
        let responses = try await withThrowingTaskGroup(
            of: JellyfinLiveTVQueryResultDTO.self,
            returning: [JellyfinLiveTVQueryResultDTO].self
        ) { group in
            for ids in chunks {
                group.addTask { [transport, session] in
                    try await transport.get(
                        "/LiveTv/Programs",
                        queryItems: [
                            URLQueryItem(name: "UserId", value: session.user.id),
                            URLQueryItem(name: "ChannelIds", value: ids.joined(separator: ",")),
                            URLQueryItem(name: "MinStartDate", value: start),
                            URLQueryItem(name: "MaxEndDate", value: end),
                            URLQueryItem(name: "EnableImages", value: "true"),
                            URLQueryItem(name: "EnableUserData", value: "true"),
                            URLQueryItem(name: "Fields", value: "ChannelId,Genres,Tags,Overview")
                        ],
                        token: session.accessToken
                    )
                }
            }
            var values: [JellyfinLiveTVQueryResultDTO] = []
            for try await response in group { values.append(response) }
            return values
        }

        var programs: [String: [UnifiedProgram]] = [:]
        for response in responses {
            for item in response.items {
                guard let rawChannelID = item.channelID,
                      let unifiedChannelID = channelLookup[rawChannelID],
                      let program = JellyfinLiveTVMapper.program(
                        item,
                        unifiedChannelID: unifiedChannelID,
                        imageBuilder: imageBuilder
                      ) else { continue }
                programs[unifiedChannelID, default: []].append(program)
            }
        }
        for channelID in programs.keys {
            programs[channelID]?.sort { $0.startTime < $1.startTime }
        }
        var merged = cachedEPG
        for (channelID, incoming) in programs {
            var known = Dictionary(uniqueKeysWithValues: (merged[channelID] ?? []).map { ($0.id, $0) })
            for program in incoming { known[program.id] = program }
            merged[channelID] = known.values.sorted { $0.startTime < $1.startTime }
        }
        cachedEPG = merged
        if let range = cachedEPGRange {
            cachedEPGRange = (min(range.start, startDate), max(range.end, endDate))
        } else {
            cachedEPGRange = (startDate, endDate)
        }
        lastEPGFetch = Date()
        return filteredEPG(merged, channels: channels, startDate: startDate, endDate: endDate)
    }

    func getCurrentProgram(for channel: UnifiedChannel) async -> UnifiedProgram? {
        let now = Date()
        return cachedEPG[channel.id]?.first { $0.startTime <= now && $0.endTime > now }
    }

    nonisolated func buildStreamURL(for channel: UnifiedChannel) -> URL? {
        // Jellyfin must open/authorize a LiveStream through PlaybackInfo first.
        nil
    }

    func resolveStream(for channel: UnifiedChannel) async -> ResolvedLiveTVStream? {
        guard let itemID = channel.tvgId, !itemID.isEmpty else { return nil }
        do {
            let request = JellyfinPlaybackInfoRequest(
                userID: session.user.id,
                autoOpenLiveStream: true,
                capabilities: Self.playbackCapabilities
            )
            let response: JellyfinPlaybackInfoResponse = try await transport.post(
                "/Items/\(itemID)/PlaybackInfo",
                body: request,
                token: session.accessToken
            )
            guard let selected = JellyfinSourceSelector.best(
                from: response.mediaSources,
                capabilities: Self.playbackCapabilities
            ) else { return nil }
            let playable = try JellyfinPlaybackURLBuilder.playableRequest(
                serverURL: transport.baseURL,
                itemID: itemID,
                source: selected.source,
                delivery: selected.delivery,
                playSessionID: response.playSessionID,
                audioStreamIndex: selected.source.defaultAudioStreamIndex,
                subtitleStreamIndex: selected.source.defaultSubtitleStreamIndex,
                authorizationHeader: session.clientIdentity.authorizationHeader(token: session.accessToken)
            )

            let lifecycleID = UUID().uuidString
            let context = JellyfinPlaybackReportContext(
                itemID: itemID,
                mediaSourceID: playable.sourceID,
                playSessionID: response.playSessionID,
                liveStreamID: playable.lifecycle.liveStreamID,
                delivery: playable.delivery,
                audioStreamIndex: selected.source.defaultAudioStreamIndex,
                subtitleStreamIndex: selected.source.defaultSubtitleStreamIndex,
                canSeek: false
            )
            activePlayback[lifecycleID] = context
            let reporter = JellyfinProgressReporter(
                transport: transport,
                token: session.accessToken,
                context: context
            )
            await reporter.start()

            var headers = playable.headers
            headers["User-Agent"] = LiveTVClientIdentity.userAgent
            return ResolvedLiveTVStream(
                url: playable.url,
                headers: headers,
                forceEngineDemux: selected.delivery == .directPlay
                    && playable.url.pathExtension.lowercased() != "m3u8",
                sessionID: lifecycleID
            )
        } catch {
            return nil
        }
    }

    func resolveStreamURL(for channel: UnifiedChannel) async -> URL? {
        await resolveStream(for: channel)?.url
    }

    func endStream(_ stream: ResolvedLiveTVStream) async {
        guard let lifecycleID = stream.sessionID,
              let context = activePlayback.removeValue(forKey: lifecycleID) else { return }
        let reporter = JellyfinProgressReporter(
            transport: transport,
            token: session.accessToken,
            context: context
        )
        await reporter.stopped(at: 0)
    }

    private func filteredEPG(
        _ values: [String: [UnifiedProgram]],
        channels: [UnifiedChannel],
        startDate: Date,
        endDate: Date
    ) -> [String: [UnifiedProgram]] {
        let allowed = Set(channels.map(\.id))
        return values.reduce(into: [:]) { result, entry in
            guard allowed.contains(entry.key) else { return }
            let programs = entry.value.filter { $0.endTime > startDate && $0.startTime < endDate }
            if !programs.isEmpty { result[entry.key] = programs }
        }
    }

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
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: maxCount).map {
            Array(self[$0..<Swift.min($0 + maxCount, count)])
        }
    }
}
