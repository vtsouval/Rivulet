// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class JellyfinPlaybackModelsTests: XCTestCase {
    func test_playbackInfo_decodesMediaSourceStreamsHeadersAndLifecycle() throws {
        let json = #"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "source-1",
            "Name": "1080p WEB-DL",
            "Path": "gelato://movie/123",
            "Protocol": "Http",
            "Type": "Default",
            "Container": "mkv",
            "Size": 5368709120,
            "Bitrate": 8500000,
            "RunTimeTicks": 72000000000,
            "IsRemote": true,
            "SupportsDirectPlay": true,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true,
            "RequiresOpening": true,
            "OpenToken": "open-token",
            "RequiresClosing": true,
            "LiveStreamId": "live-1",
            "DefaultAudioStreamIndex": 1,
            "DefaultSubtitleStreamIndex": 2,
            "RequiredHttpHeaders": { "Referer": "https://origin.invalid/" },
            "TranscodingUrl": "/Videos/123/master.m3u8?MediaSourceId=source-1",
            "TranscodingContainer": "ts",
            "TranscodingSubProtocol": "hls",
            "MediaStreams": [
              {
                "Index": 0, "Type": "Video", "Codec": "hevc",
                "Width": 1920, "Height": 1080, "BitRate": 8000000,
                "VideoRangeType": "HDR10", "DvProfile": 8,
                "Hdr10PlusPresentFlag": true
              },
              {
                "Index": 1, "Type": "Audio", "Codec": "eac3",
                "Language": "eng", "Channels": 6, "IsDefault": true
              },
              {
                "Index": 2, "Type": "Subtitle", "Codec": "subrip",
                "Language": "eng", "IsExternal": true,
                "DeliveryMethod": "External", "DeliveryUrl": "/Videos/123/Subtitles/2/Stream.srt"
              }
            ]
          }]
        }
        """#

        let response = try JSONDecoder().decode(JellyfinPlaybackInfoResponse.self, from: Data(json.utf8))
        let source = try XCTUnwrap(response.mediaSources.first)

        XCTAssertEqual(response.playSessionID, "play-1")
        XCTAssertEqual(source.id, "source-1")
        XCTAssertEqual(source.size, 5_368_709_120)
        XCTAssertEqual(source.videoWidth, 1920)
        XCTAssertEqual(source.videoHeight, 1080)
        XCTAssertEqual(source.videoStreams.first?.videoRangeType, "HDR10")
        XCTAssertEqual(source.audioStreams.first?.channels, 6)
        XCTAssertEqual(source.subtitleStreams.first?.deliveryMethod, "External")
        XCTAssertEqual(source.requiredHTTPHeaders["Referer"], "https://origin.invalid/")
        XCTAssertTrue(source.isGelatoVirtual)
        XCTAssertEqual(
            source.liveStreamLifecycle,
            JellyfinLiveStreamLifecycle(
                requiresOpening: true,
                openToken: "open-token",
                liveStreamID: "live-1",
                requiresClosing: true
            )
        )
    }

    func test_playbackInfo_toleratesMissingArraysAndUnknownStreamKind() throws {
        let empty = try JSONDecoder().decode(
            JellyfinPlaybackInfoResponse.self,
            from: Data(#"{"PlaySessionId":"p"}"#.utf8)
        )
        XCTAssertTrue(empty.mediaSources.isEmpty)

        let stream = try JSONDecoder().decode(
            JellyfinMediaStream.self,
            from: Data(#"{"Type":"FutureStream","Index":9}"#.utf8)
        )
        XCTAssertEqual(stream.type, .other("FutureStream"))
    }

    func test_playbackInfoRequest_encodesOfficialJellyfinKeys() throws {
        let capabilities = JellyfinPlaybackCapabilities(
            allowsDirectPlay: true,
            allowsRemux: true,
            allowsTranscoding: false,
            allowsVideoStreamCopy: true,
            allowsAudioStreamCopy: false,
            maxStreamingBitrate: 12_000_000,
            maxVideoWidth: 1920,
            maxVideoHeight: 1080,
            maxAudioChannels: 8
        )
        let request = JellyfinPlaybackInfoRequest(
            userID: "user-1",
            startPosition: 12.5,
            audioStreamIndex: 1,
            subtitleStreamIndex: 2,
            mediaSourceID: "source-1",
            autoOpenLiveStream: true,
            capabilities: capabilities
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["UserId"] as? String, "user-1")
        XCTAssertEqual(object["StartTimeTicks"] as? Int, 125_000_000)
        XCTAssertEqual(object["MediaSourceId"] as? String, "source-1")
        XCTAssertEqual(object["AutoOpenLiveStream"] as? Bool, true)
        XCTAssertEqual(object["EnableDirectPlay"] as? Bool, true)
        XCTAssertEqual(object["EnableDirectStream"] as? Bool, true)
        XCTAssertEqual(object["EnableTranscoding"] as? Bool, false)
        XCTAssertEqual(object["AllowVideoStreamCopy"] as? Bool, true)
        XCTAssertEqual(object["AllowAudioStreamCopy"] as? Bool, false)
        XCTAssertEqual(object["MaxStreamingBitrate"] as? Int, 12_000_000)
        XCTAssertEqual(object["MaxAudioChannels"] as? Int, 8)
    }

    func test_playbackInfoRequest_preservesExplicitSubtitleOffAndResumeTicks() throws {
        let request = JellyfinPlaybackInfoRequest(
            userID: "user-1",
            startPosition: 42.75,
            subtitleStreamIndex: -1
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["StartTimeTicks"] as? Int, 427_500_000)
        XCTAssertEqual(object["SubtitleStreamIndex"] as? Int, -1)
    }

    func test_ticksClampInvalidAndRoundTrip() {
        XCTAssertEqual(JellyfinTicks.fromSeconds(-1), 0)
        XCTAssertEqual(JellyfinTicks.fromSeconds(.nan), 0)
        XCTAssertEqual(JellyfinTicks.fromSeconds(1.25), 12_500_000)
        XCTAssertEqual(JellyfinTicks.toSeconds(12_500_000), 1.25)
    }
}
