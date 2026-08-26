// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum JellyfinPlaybackURLBuilderError: Error, Equatable, Sendable {
    case invalidServerURL
    case missingItemID
    case missingSourceID
    case missingTranscodingURL
    case invalidPlaybackURL
    case crossOriginPlaybackURL
}

nonisolated struct JellyfinPlayableRequest: Sendable {
    let url: URL
    let headers: [String: String]
    let delivery: JellyfinPlaybackDelivery
    let sourceID: String
    let lifecycle: JellyfinLiveStreamLifecycle

    /// Materializes the provider-neutral result consumed by the existing
    /// playback boundary. The unresolved source contributes display/track
    /// metadata; this request contributes the negotiated URL and headers.
    func streamInfo(
        replacing source: MediaSource,
        playSessionID: String?,
        trackInfoAvailable: Bool? = nil
    ) -> StreamInfo {
        let streamKind: MediaSource.StreamKind
        switch delivery {
        case .directPlay:
            streamKind = .directPlay
        case .remux, .transcode:
            streamKind = .hlsTranscode
        }
        let resolvedSource = MediaSource(
            id: source.id,
            container: source.container,
            duration: source.duration,
            bitrate: source.bitrate,
            fileSize: source.fileSize,
            fileName: source.fileName,
            videoResolution: source.videoResolution,
            videoTracks: source.videoTracks,
            audioTracks: source.audioTracks,
            subtitleTracks: source.subtitleTracks,
            streamKind: streamKind,
            streamURL: url
        )
        return StreamInfo(
            source: resolvedSource,
            playSessionID: playSessionID,
            trackInfoAvailable: trackInfoAvailable ?? (delivery == .directPlay),
            requestHeaders: headers,
            liveStreamID: lifecycle.liveStreamID,
            requiresLiveStreamClose: lifecycle.requiresClosing
        )
    }
}

/// Builds player requests without exposing Jellyfin or upstream credentials in
/// URLs. Direct playback is still served by Jellyfin's `/Videos/.../stream`
/// endpoint; `Path` may be a local file or a Gelato/debrid URL and is therefore
/// never handed to the client.
nonisolated enum JellyfinPlaybackURLBuilder {
    static func playableRequest(
        serverURL: URL,
        itemID: String,
        source: JellyfinMediaSourceInfo,
        delivery: JellyfinPlaybackDelivery,
        playSessionID: String?,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        authorizationHeader: String
    ) throws -> JellyfinPlayableRequest {
        let baseURL = try sanitizedServerURL(serverURL)
        guard !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JellyfinPlaybackURLBuilderError.missingItemID
        }
        guard let sourceID = source.id, !sourceID.isEmpty else {
            throw JellyfinPlaybackURLBuilderError.missingSourceID
        }

        let url: URL
        switch delivery {
        case .directPlay:
            url = try directStreamURL(
                serverURL: baseURL,
                itemID: itemID,
                sourceID: sourceID,
                playSessionID: playSessionID,
                liveStreamID: source.liveStreamID,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex
            )
        case .remux, .transcode:
            guard let transcodingURL = source.transcodingURL, !transcodingURL.isEmpty else {
                throw JellyfinPlaybackURLBuilderError.missingTranscodingURL
            }
            url = try returnedServerURL(transcodingURL, relativeTo: baseURL)
        }

        return JellyfinPlayableRequest(
            url: url,
            headers: safeHeaders(
                requiredHeaders: source.requiredHTTPHeaders,
                authorizationHeader: authorizationHeader
            ),
            delivery: delivery,
            sourceID: sourceID,
            lifecycle: source.liveStreamLifecycle
        )
    }

    static func returnedServerURL(_ value: String, relativeTo serverURL: URL) throws -> URL {
        let baseURL = try sanitizedServerURL(serverURL)
        let resolved: URL?
        if let candidate = URL(string: value), candidate.scheme != nil {
            resolved = candidate
        } else if value.hasPrefix("/") {
            let relative = URLComponents(string: value)
            var root = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            root?.path = relative?.path ?? value
            root?.percentEncodedQuery = relative?.percentEncodedQuery
            root?.fragment = nil
            resolved = root?.url
        } else {
            let directoryBase = baseURL.absoluteString.hasSuffix("/")
                ? baseURL
                : URL(string: baseURL.absoluteString + "/") ?? baseURL
            resolved = URL(string: value, relativeTo: directoryBase)?.absoluteURL
        }

        guard var components = resolved.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              sameOrigin(components.url, baseURL) else {
            if let resolved, !sameOrigin(resolved, baseURL) {
                throw JellyfinPlaybackURLBuilderError.crossOriginPlaybackURL
            }
            throw JellyfinPlaybackURLBuilderError.invalidPlaybackURL
        }

        components.fragment = nil
        components.queryItems = sanitizedQueryItems(components.queryItems)
        guard let url = components.url else {
            throw JellyfinPlaybackURLBuilderError.invalidPlaybackURL
        }
        return url
    }

    private static func directStreamURL(
        serverURL: URL,
        itemID: String,
        sourceID: String,
        playSessionID: String?,
        liveStreamID: String?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) throws -> URL {
        var url = serverURL
        url.appendPathComponent("Videos")
        url.appendPathComponent(itemID)
        url.appendPathComponent("stream")

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackURLBuilderError.invalidPlaybackURL
        }
        var queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: sourceID)
        ]
        if let playSessionID, !playSessionID.isEmpty {
            queryItems.append(URLQueryItem(name: "playSessionId", value: playSessionID))
        }
        if let liveStreamID, !liveStreamID.isEmpty {
            queryItems.append(URLQueryItem(name: "liveStreamId", value: liveStreamID))
        }
        if let audioStreamIndex {
            queryItems.append(URLQueryItem(name: "audioStreamIndex", value: String(audioStreamIndex)))
        }
        if let subtitleStreamIndex {
            queryItems.append(URLQueryItem(name: "subtitleStreamIndex", value: String(subtitleStreamIndex)))
        }
        components.queryItems = queryItems
        guard let result = components.url else {
            throw JellyfinPlaybackURLBuilderError.invalidPlaybackURL
        }
        return result
    }

    private static func sanitizedServerURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            throw JellyfinPlaybackURLBuilderError.invalidServerURL
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        guard let result = components.url else {
            throw JellyfinPlaybackURLBuilderError.invalidServerURL
        }
        return result
    }

    private static func safeHeaders(
        requiredHeaders: [String: String],
        authorizationHeader: String
    ) -> [String: String] {
        let blocked = Set([
            "connection", "content-length", "cookie", "host", "proxy-authorization",
            "set-cookie", "te", "trailer", "transfer-encoding", "upgrade"
        ])
        var result: [String: String] = [:]
        for (name, value) in requiredHeaders {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  !blocked.contains(trimmedName.lowercased()),
                  !trimmedName.contains(":"),
                  !trimmedName.contains(where: { $0.isNewline }),
                  !value.contains(where: { $0.isNewline }) else {
                continue
            }
            result[trimmedName] = value
        }

        // A media source can request headers for its upstream origin, but it
        // must never replace the credential for Rivulet's Jellyfin session.
        result = result.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        if !authorizationHeader.isEmpty,
           !authorizationHeader.contains(where: { $0.isNewline }) {
            result["Authorization"] = authorizationHeader
        }
        result["Accept"] = "*/*"
        return result
    }

    private static func sanitizedQueryItems(_ items: [URLQueryItem]?) -> [URLQueryItem]? {
        let sensitiveNames = Set(["api_key", "apikey", "access_token", "token", "x-emby-token"])
        let filtered = (items ?? []).filter { !sensitiveNames.contains($0.name.lowercased()) }
        return filtered.isEmpty ? nil : filtered
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else {
            return false
        }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && effectivePort(left) == effectivePort(right)
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
