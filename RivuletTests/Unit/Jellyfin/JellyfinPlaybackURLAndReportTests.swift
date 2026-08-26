// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class JellyfinPlaybackURLAndReportTests: XCTestCase {
    func test_directPlayUsesJellyfinEndpointAndNeverExposesGelatoPath() throws {
        let source = try decodeSource(#"""
        {
          "Id":"gelato:source/1",
          "Path":"gelato://real-debrid/secret-upstream-url",
          "SupportsDirectPlay":true,
          "RequiredHttpHeaders":{
            "Referer":"https://origin.invalid/",
            "Authorization":"untrusted",
            "Host":"evil.invalid",
            "X-Newline":"bad\r\nInjected: yes"
          },
          "LiveStreamId":"live-1",
          "RequiresClosing":true
        }
        """#)

        let request = try JellyfinPlaybackURLBuilder.playableRequest(
            serverURL: try XCTUnwrap(URL(string: "https://flix.example/jellyfin")),
            itemID: "item / 1",
            source: source,
            delivery: .directPlay,
            playSessionID: "play-1",
            audioStreamIndex: 1,
            subtitleStreamIndex: 2,
            authorizationHeader: "MediaBrowser Token=good"
        )

        XCTAssertEqual(request.url.host, "flix.example")
        XCTAssertTrue(request.url.path.hasSuffix("/Videos/item / 1/stream"))
        XCTAssertFalse(request.url.absoluteString.contains("real-debrid"))
        XCTAssertFalse(request.url.absoluteString.lowercased().contains("token"))
        let query = queryItems(request.url)
        XCTAssertEqual(query["static"], "true")
        XCTAssertEqual(query["mediaSourceId"], "gelato:source/1")
        XCTAssertEqual(query["playSessionId"], "play-1")
        XCTAssertEqual(query["liveStreamId"], "live-1")
        XCTAssertEqual(request.headers["Authorization"], "MediaBrowser Token=good")
        XCTAssertEqual(request.headers["Referer"], "https://origin.invalid/")
        XCTAssertNil(request.headers["Host"])
        XCTAssertNil(request.headers["X-Newline"])
        XCTAssertTrue(request.lifecycle.requiresClosing)

        let unresolved = MediaSource(
            id: "gelato:source/1", container: "mkv", duration: 100,
            bitrate: 1_000_000, fileSize: nil, fileName: "Movie",
            videoResolution: "1080", videoTracks: [], audioTracks: [],
            subtitleTracks: [], streamKind: .directPlay, streamURL: nil
        )
        let streamInfo = request.streamInfo(replacing: unresolved, playSessionID: "play-1")
        XCTAssertEqual(streamInfo.source.streamURL, request.url)
        XCTAssertEqual(streamInfo.requestHeaders["Authorization"], "MediaBrowser Token=good")
        XCTAssertEqual(streamInfo.liveStreamID, "live-1")
        XCTAssertTrue(streamInfo.requiresLiveStreamClose)
        XCTAssertTrue(streamInfo.trackInfoAvailable)
    }

    func test_transcodeURLMustRemainOnConfiguredJellyfinOrigin() throws {
        let source = try decodeSource(#"""
        {"Id":"s","TranscodingUrl":"https://evil.invalid/master.m3u8","SupportsTranscoding":true}
        """#)
        XCTAssertThrowsError(
            try JellyfinPlaybackURLBuilder.playableRequest(
                serverURL: XCTUnwrap(URL(string: "https://flix.example")),
                itemID: "item",
                source: source,
                delivery: .transcode,
                playSessionID: nil,
                authorizationHeader: "auth"
            )
        ) { error in
            XCTAssertEqual(error as? JellyfinPlaybackURLBuilderError, .crossOriginPlaybackURL)
        }
    }

    func test_authorizationHeaderRejectsHeaderInjection() throws {
        let source = try decodeSource(#"{"Id":"s","SupportsDirectPlay":true}"#)
        let request = try JellyfinPlaybackURLBuilder.playableRequest(
            serverURL: try XCTUnwrap(URL(string: "https://flix.example")),
            itemID: "item",
            source: source,
            delivery: .directPlay,
            playSessionID: nil,
            authorizationHeader: "MediaBrowser Token=good\r\nX-Injected: yes"
        )

        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(request.headers["Accept"], "*/*")
    }

    func test_relativeTranscodeURLPreservesParametersButStripsCredentialQuery() throws {
        let source = try decodeSource(#"""
        {
          "Id":"s",
          "TranscodingUrl":"/Videos/item/master.m3u8?MediaSourceId=s&api_key=secret&h264-level=51",
          "SupportsTranscoding":true
        }
        """#)
        let request = try JellyfinPlaybackURLBuilder.playableRequest(
            serverURL: try XCTUnwrap(URL(string: "https://flix.example/jellyfin")),
            itemID: "item",
            source: source,
            delivery: .transcode,
            playSessionID: nil,
            authorizationHeader: "auth"
        )

        XCTAssertEqual(request.url.path, "/Videos/item/master.m3u8")
        XCTAssertEqual(queryItems(request.url)["MediaSourceId"], "s")
        XCTAssertEqual(queryItems(request.url)["h264-level"], "51")
        XCTAssertNil(queryItems(request.url)["api_key"])
    }

    func test_pauseAndStopReportsCarryExactSessionAndLiveStreamState() throws {
        let context = JellyfinPlaybackReportContext(
            itemID: "item-1",
            mediaSourceID: "source-1",
            playSessionID: "play-1",
            liveStreamID: "live-1",
            delivery: .remux,
            audioStreamIndex: 3,
            subtitleStreamIndex: 4,
            canSeek: false
        )
        let pause = JellyfinPlaybackProgressRequest.paused(
            context: context,
            position: 61.25,
            isMuted: true,
            volumeLevel: 120
        )
        let pauseJSON = try jsonObject(pause)
        XCTAssertEqual(pauseJSON["ItemId"] as? String, "item-1")
        XCTAssertEqual(pauseJSON["MediaSourceId"] as? String, "source-1")
        XCTAssertEqual(pauseJSON["PlaySessionId"] as? String, "play-1")
        XCTAssertEqual(pauseJSON["LiveStreamId"] as? String, "live-1")
        XCTAssertEqual(pauseJSON["PlayMethod"] as? String, "DirectStream")
        XCTAssertEqual(pauseJSON["PositionTicks"] as? Int, 612_500_000)
        XCTAssertEqual(pauseJSON["IsPaused"] as? Bool, true)
        XCTAssertEqual(pauseJSON["IsMuted"] as? Bool, true)
        XCTAssertEqual(pauseJSON["CanSeek"] as? Bool, false)
        XCTAssertEqual(pauseJSON["VolumeLevel"] as? Int, 100)

        let stopJSON = try jsonObject(
            JellyfinPlaybackStopRequest(context: context, position: 62, failed: true)
        )
        XCTAssertEqual(stopJSON["PositionTicks"] as? Int, 620_000_000)
        XCTAssertEqual(stopJSON["LiveStreamId"] as? String, "live-1")
        XCTAssertEqual(stopJSON["Failed"] as? Bool, true)
    }

    func test_startReportIsNotPausedAndUsesNegotiatedMethod() throws {
        let context = JellyfinPlaybackReportContext(
            itemID: "item", mediaSourceID: "source", playSessionID: "session",
            delivery: .directPlay
        )
        let json = try jsonObject(JellyfinPlaybackStartRequest(context: context, position: 0))
        XCTAssertEqual(json["PlayMethod"] as? String, "DirectPlay")
        XCTAssertEqual(json["IsPaused"] as? Bool, false)
        XCTAssertEqual(json["PositionTicks"] as? Int, 0)
    }

    private func decodeSource(_ json: String) throws -> JellyfinMediaSourceInfo {
        try JSONDecoder().decode(JellyfinMediaSourceInfo.self, from: Data(json.utf8))
    }

    private func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
