// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class JellyfinSourceSelectorTests: XCTestCase {
    func test_directPlayWinsWhenDirectnessIsPrioritized() throws {
        let direct720 = try source(
            id: "direct-720", path: "/media/a.mkv", height: 720,
            bitrate: 4_000_000, direct: true, remux: true, transcode: true
        )
        let transcode1080 = try source(
            id: "transcode-1080", path: "/media/b.mkv", height: 1080,
            bitrate: 8_000_000, direct: false, remux: false, transcode: true,
            transcodingURL: "/Videos/b/master.m3u8"
        )

        let result = JellyfinSourceSelector.best(
            from: [transcode1080, direct720],
            capabilities: JellyfinPlaybackCapabilities(),
            policy: JellyfinSourceSelectionPolicy(preferredVideoHeight: 1080)
        )
        XCTAssertEqual(result?.source.id, "direct-720")
        XCTAssertEqual(result?.delivery, .directPlay)
    }

    func test_qualityCanLeadWhenPolicyDoesNotPrioritizeDirectness() throws {
        let direct720 = try source(
            id: "direct-720", path: "/media/a.mkv", height: 720,
            bitrate: 4_000_000, direct: true, remux: true, transcode: true
        )
        let transcode1080 = try source(
            id: "transcode-1080", path: "/media/b.mkv", height: 1080,
            bitrate: 8_000_000, direct: false, remux: false, transcode: true,
            transcodingURL: "/Videos/b/master.m3u8"
        )

        let result = JellyfinSourceSelector.best(
            from: [direct720, transcode1080],
            capabilities: JellyfinPlaybackCapabilities(),
            policy: JellyfinSourceSelectionPolicy(
                preferredVideoHeight: 1080,
                prioritizesDirectness: false
            )
        )
        XCTAssertEqual(result?.source.id, "transcode-1080")
        XCTAssertEqual(result?.delivery, .transcode)
    }

    func test_bitrateOrResolutionLimitForcesServerTranscode() throws {
        let source = try source(
            id: "4k", path: "/media/4k.mkv", width: 3840, height: 2160,
            bitrate: 45_000_000, direct: true, remux: true, transcode: true,
            transcodingURL: "/Videos/4k/master.m3u8"
        )
        let capabilities = JellyfinPlaybackCapabilities(
            maxStreamingBitrate: 12_000_000,
            maxVideoWidth: 1920,
            maxVideoHeight: 1080
        )

        XCTAssertEqual(
            JellyfinSourceSelector.best(from: [source], capabilities: capabilities)?.delivery,
            .transcode
        )
        XCTAssertEqual(
            JellyfinSourceSelector.supportedDeliveries(for: source, capabilities: capabilities),
            [.transcode]
        )
    }

    func test_explicitGelatoSourceIsPlayableWithoutAFilePath() throws {
        let local = try source(
            id: "local", path: "/media/local.mkv", height: 1080,
            bitrate: 8_000_000, direct: true, remux: true, transcode: true
        )
        let gelato = try source(
            id: "gelato:rd-1", path: "gelato://rd/movie/1", height: 1080,
            bitrate: 7_000_000, direct: true, remux: true, transcode: true
        )

        XCTAssertTrue(gelato.isGelatoVirtual)
        let result = JellyfinSourceSelector.best(
            from: [local, gelato],
            capabilities: JellyfinPlaybackCapabilities(),
            policy: JellyfinSourceSelectionPolicy(preferredSourceID: "gelato:rd-1")
        )
        XCTAssertEqual(result?.source.id, "gelato:rd-1")
        XCTAssertEqual(result?.delivery, .directPlay)
    }

    func test_tieBreakIsDeterministicAcrossServerOrdering() throws {
        let a = try source(
            id: "a", path: "/a", height: 1080, bitrate: 8_000_000,
            direct: true, remux: true, transcode: true
        )
        let b = try source(
            id: "b", path: "/b", height: 1080, bitrate: 8_000_000,
            direct: true, remux: true, transcode: true
        )
        let capabilities = JellyfinPlaybackCapabilities()
        let first = JellyfinSourceSelector.ranked(from: [b, a], capabilities: capabilities).map { $0.source.id }
        let second = JellyfinSourceSelector.ranked(from: [a, b], capabilities: capabilities).map { $0.source.id }

        XCTAssertEqual(first, ["a", "b"])
        XCTAssertEqual(second, first)
    }

    private func source(
        id: String,
        path: String,
        width: Int = 1920,
        height: Int,
        bitrate: Int,
        direct: Bool,
        remux: Bool,
        transcode: Bool,
        transcodingURL: String? = nil
    ) throws -> JellyfinMediaSourceInfo {
        var object: [String: Any] = [
            "Id": id,
            "Path": path,
            "Bitrate": bitrate,
            "SupportsDirectPlay": direct,
            "SupportsDirectStream": remux,
            "SupportsTranscoding": transcode,
            "MediaStreams": [["Index": 0, "Type": "Video", "Width": width, "Height": height]]
        ]
        object["TranscodingUrl"] = transcodingURL
        return try JSONDecoder().decode(
            JellyfinMediaSourceInfo.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
