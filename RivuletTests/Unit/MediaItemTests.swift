// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItemTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemTests: XCTestCase {
    func test_id_returnsRef() {
        let ref = MediaItemRef(providerID: "plex:abc", itemID: "1")
        let item = MediaItem(
            ref: ref,
            kind: .movie,
            title: "Inception",
            sortTitle: nil,
            overview: nil,
            year: 2010,
            runtime: 8880,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
        XCTAssertEqual(item.id, ref)
    }

    func test_episodePresentationUsesSeriesSeasonAndEpisodeHierarchy() {
        let item = MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:server", itemID: "episode-3"),
            kind: .episode,
            title: "The Crossing",
            sortTitle: nil,
            overview: nil,
            year: 2026,
            runtime: 2_700,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: 3,
            seasonNumber: 2,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil,
            seriesTitle: "Northern Lights",
            seasonTitle: "The Long Winter"
        )

        XCTAssertEqual(item.episodeString, "S02E03")
        XCTAssertEqual(item.episodeCoordinate, "S2, E3")
        XCTAssertEqual(item.episodeHierarchyTitle, "Northern Lights  ·  S2, E3")
        XCTAssertEqual(item.seasonDisplayTitle, "The Long Winter")
    }
}
