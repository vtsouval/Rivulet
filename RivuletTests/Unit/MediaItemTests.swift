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

    func test_seasonZeroAlwaysUsesSpecialsEvenWhenServerCallsItSeasonZero() {
        let item = MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:server", itemID: "special-1"),
            kind: .episode, title: "Holiday Special", sortTitle: nil, overview: nil,
            year: 2026, runtime: 2_700, parentRef: nil, grandparentRef: nil,
            episodeNumber: 1, seasonNumber: 0, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            seriesTitle: "Northern Lights", seasonTitle: "Season 0"
        )

        XCTAssertEqual(item.seasonDisplayTitle, "Specials")
        XCTAssertEqual(item.episodeString, "Special 1")
        XCTAssertEqual(item.episodeCoordinate, "Special 1")
        XCTAssertEqual(item.episodeHierarchyTitle, "Northern Lights  ·  Special 1")
    }

    func test_animeClassificationDoesNotHideGenericAnimation() {
        let base = MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:server", itemID: "animation"),
            kind: .show, title: "Animated", sortTitle: nil, overview: nil,
            year: 2026, runtime: nil, genres: ["Animation"], tags: [],
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
        var anime = base
        anime = MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:server", itemID: "anime"),
            kind: .show, title: "Anime", sortTitle: nil, overview: nil,
            year: 2026, runtime: nil, genres: ["Animation"], tags: ["Anime"],
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
            childProgress: nil, userState: base.userState, artwork: base.artwork,
            parentArtwork: nil, grandparentArtwork: nil
        )
        XCTAssertFalse(base.isAnime)
        XCTAssertTrue(anime.isAnime)
    }

    func test_continueWatchingEpisodeUsesSeriesEpisodeCoordinateAndRemainingTime() {
        let item = MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:server", itemID: "episode-7"),
            kind: .episode, title: "The Crossing", sortTitle: nil, overview: nil,
            year: 2026, runtime: 2_700, parentRef: nil, grandparentRef: nil,
            episodeNumber: 7, seasonNumber: 1, childProgress: nil,
            userState: MediaUserState(
                isPlayed: false, viewOffset: 1_620, isFavorite: false, lastViewedAt: Date()
            ),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            seriesTitle: "Northern Lights", seasonTitle: "Season 1"
        )

        XCTAssertEqual(item.continueWatchingTitle, "Northern Lights")
        XCTAssertEqual(item.continueWatchingSubtitle, "The Crossing")
        XCTAssertEqual(item.remainingTimeFormatted, "18m left")
        XCTAssertEqual(item.continueWatchingProgressLabel, "S1, E7  ·  18m left")
        XCTAssertEqual(item.watchProgress ?? -1, 0.6, accuracy: 0.001)
    }

    func test_continueWatchingMovieKeepsMovieTitleAndUsesHoursRemaining() {
        let item = MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:server", itemID: "movie"),
            kind: .movie, title: "Arrival", sortTitle: nil, overview: nil,
            year: 2016, runtime: 7_200, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(
                isPlayed: false, viewOffset: 1_200, isFavorite: false, lastViewedAt: Date()
            ),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )

        XCTAssertEqual(item.continueWatchingTitle, "Arrival")
        XCTAssertNil(item.continueWatchingSubtitle)
        XCTAssertEqual(item.continueWatchingProgressLabel, "1h 40m left")
    }

    func test_searchSectionsGroupTitleLevelMediaAndRemoveDuplicates() {
        let movie = searchItem(id: "movie", kind: .movie, title: "Arrival")
        let duplicateEdition = searchItem(id: "movie-alt", kind: .movie, title: "Arrival")
        let show = searchItem(id: "show", kind: .show, title: "Severance")
        let episode = searchItem(id: "episode", kind: .episode, title: "Good News About Hell")

        let sections = MediaSearchSections([show, movie, episode, movie, duplicateEdition])

        XCTAssertEqual(sections.movies.map(\.title), ["Arrival"])
        XCTAssertEqual(sections.shows.map(\.title), ["Severance"])
        XCTAssertEqual(sections.all.map(\.title), ["Arrival", "Severance"])
        XCTAssertFalse(sections.isEmpty)
        XCTAssertTrue(MediaSearchSections([episode]).isEmpty)
    }

    private func searchItem(id: String, kind: MediaKind, title: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:server", itemID: id),
            kind: kind, title: title, sortTitle: nil, overview: nil,
            year: 2026, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }
}
