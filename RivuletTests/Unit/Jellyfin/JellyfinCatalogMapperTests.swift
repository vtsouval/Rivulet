// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

final class JellyfinCatalogMapperTests: XCTestCase {
    private var context: JellyfinCatalogContext!

    override func setUpWithError() throws {
        context = try XCTUnwrap(JellyfinCatalogContext(
            serverID: "server-a",
            imageBuilder: JellyfinImageURLBuilder(
                serverURL: try XCTUnwrap(URL(string: "https://media.example.com/jellyfin")),
                accessToken: "access-token"
            )
        ))
    }

    func testLibraryMapsKnownCollectionTypesAndScopesIdentity() throws {
        let view: JellyfinBaseItemDTO = try decode(
            """
            { "Id":"library-1", "Name":"TV Shows", "CollectionType":"tvshows" }
            """
        )
        let library = try XCTUnwrap(JellyfinCatalogMapper.library(view, context: context))

        XCTAssertEqual(library.id, "library-1")
        XCTAssertEqual(library.providerID, "jellyfin:server-a")
        XCTAssertEqual(library.kind, .shows)
        XCTAssertEqual(JellyfinCatalogMapper.libraryKind("unknown-future-type"), .mixed)
    }

    func testAllCatalogKindsMapWithoutDependingOnWireEnumExhaustiveness() {
        XCTAssertEqual(JellyfinCatalogMapper.kind("Movie"), .movie)
        XCTAssertEqual(JellyfinCatalogMapper.kind("Series"), .show)
        XCTAssertEqual(JellyfinCatalogMapper.kind("Season"), .season)
        XCTAssertEqual(JellyfinCatalogMapper.kind("Episode"), .episode)
        XCTAssertEqual(JellyfinCatalogMapper.kind("BoxSet"), .collection)
        XCTAssertEqual(JellyfinCatalogMapper.kind("Person"), .person)
        XCTAssertEqual(JellyfinCatalogMapper.kind("PluginVirtualItem"), .unknown)
        XCTAssertEqual(JellyfinCatalogMapper.kind(nil), .unknown)
    }

    func testSeasonUsesItsOwnIndexAsSeasonNumber() throws {
        let dto: JellyfinBaseItemDTO = try decode(
            """
            {
              "Id":"season-3", "ParentId":"series-1", "Name":"Season 3",
              "Type":"Season", "IndexNumber":3, "ParentIndexNumber":99
            }
            """
        )

        let item = try XCTUnwrap(JellyfinCatalogMapper.item(dto, context: context))
        XCTAssertEqual(item.parentRef?.itemID, "series-1")
        XCTAssertEqual(item.seasonNumber, 3)
        XCTAssertNil(item.episodeNumber)
    }

    func testEpisodeMapsHierarchyProgressDatesAndArtwork() throws {
        let dto: JellyfinBaseItemDTO = try decode(
            """
            {
              "Id":"episode-shared-id",
              "ServerId":"wrong-wire-server",
              "Name":"  Pilot  ",
              "SortName":"Pilot, The",
              "Type":"Episode",
              "Overview":"  The beginning.  ",
              "ProductionYear":2024,
              "PremiereDate":"2024-01-02T00:00:00.0000000Z",
              "OfficialRating":"TV-14",
              "RunTimeTicks":27000000000,
              "SeasonId":"season-1",
              "SeasonName":"Season One",
              "SeriesId":"series-1",
              "SeriesName":"The Example Show",
              "IndexNumber":2,
              "ParentIndexNumber":1,
              "ImageTags":{"Primary":"episode-primary","Thumb":"episode-thumb"},
              "ParentPrimaryImageItemId":"season-1",
              "ParentPrimaryImageTag":"season-primary",
              "SeriesPrimaryImageTag":"series-primary",
              "SeriesThumbImageTag":"series-thumb",
              "ParentBackdropItemId":"series-1",
              "ParentBackdropImageTags":["series-backdrop"],
              "UserData":{
                "Played":false,
                "IsFavorite":true,
                "PlaybackPositionTicks":125000000,
                "LastPlayedDate":"2026-08-26T12:34:56.1234567Z"
              }
            }
            """
        )
        let item = try XCTUnwrap(JellyfinCatalogMapper.item(dto, context: context))

        XCTAssertEqual(item.ref, MediaItemRef(providerID: "jellyfin:server-a", itemID: "episode-shared-id"))
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.title, "Pilot")
        XCTAssertEqual(item.runtime, 2_700)
        XCTAssertEqual(item.parentRef?.itemID, "season-1")
        XCTAssertEqual(item.grandparentRef?.itemID, "series-1")
        XCTAssertEqual(item.episodeNumber, 2)
        XCTAssertEqual(item.seasonNumber, 1)
        XCTAssertEqual(item.seriesTitle, "The Example Show")
        XCTAssertEqual(item.seasonTitle, "Season One")
        XCTAssertEqual(item.episodeHierarchyTitle, "The Example Show  ·  S1, E2")
        XCTAssertEqual(item.userState.viewOffset, 12.5)
        XCTAssertTrue(item.userState.isFavorite)
        XCTAssertNotNil(item.userState.lastViewedAt)
        XCTAssertTrue(item.artwork.thumbnail?.absoluteString.contains("episode-thumb") == true)
        XCTAssertTrue(item.parentArtwork?.poster?.absoluteString.contains("season-primary") == true)
        XCTAssertTrue(item.grandparentArtwork?.poster?.absoluteString.contains("series-primary") == true)
        XCTAssertTrue(item.grandparentArtwork?.backdrop?.absoluteString.contains("series-backdrop") == true)
    }

    func testEqualNativeIDsOnDifferentServersRemainDistinct() throws {
        let dto: JellyfinBaseItemDTO = try decode("{\"Id\":\"same\",\"Name\":\"Movie\",\"Type\":\"Movie\"}")
        let other = try XCTUnwrap(JellyfinCatalogContext(
            serverID: "server-b",
            imageBuilder: JellyfinImageURLBuilder(
                serverURL: URL(string: "https://other.example.com")!,
                accessToken: "token"
            )
        ))

        let first = try XCTUnwrap(JellyfinCatalogMapper.item(dto, context: context))
        let second = try XCTUnwrap(JellyfinCatalogMapper.item(dto, context: other))
        XCTAssertNotEqual(first.ref, second.ref)
        XCTAssertEqual(first.ref.providerID, "jellyfin:server-a")
        XCTAssertEqual(second.ref.providerID, "jellyfin:server-b")
    }

    func testSeriesChildProgressUsesUnplayedCountAndPlayedFlag() throws {
        let partial: JellyfinBaseItemDTO = try decode(
            """
            {
              "Id":"series-1", "Name":"Show", "Type":"Series",
              "RecursiveItemCount":10,
              "UserData":{"Played":false,"UnplayedItemCount":4}
            }
            """
        )
        let complete: JellyfinBaseItemDTO = try decode(
            """
            {
              "Id":"series-2", "Name":"Show", "Type":"Series",
              "RecursiveItemCount":10,
              "UserData":{"Played":true,"UnplayedItemCount":7}
            }
            """
        )

        XCTAssertEqual(JellyfinCatalogMapper.item(partial, context: context)?.childProgress, ChildProgress(played: 6, total: 10))
        XCTAssertEqual(JellyfinCatalogMapper.item(complete, context: context)?.childProgress, ChildProgress(played: 10, total: 10))
    }

    func testDetailMapsPeopleStudiosChaptersTrailerAndNextEpisode() throws {
        let dto: JellyfinBaseItemDTO = try decode(
            """
            {
              "Id":"movie-1",
              "Name":"Arrival",
              "Type":"Movie",
              "RunTimeTicks":600000000,
              "CommunityRating":11.5,
              "Taglines":["  ","Why are they here?"],
              "Genres":[" Drama ","Science Fiction"],
              "Studios":[{"Id":"studio-1","Name":"Paramount"},{"Name":"  "}],
              "ProductionLocations":["United States"],
              "ProviderIds":{"TmDb":"329865"},
              "ImageTags":{"Primary":"poster"},
              "BackdropImageTags":["backdrop"],
              "People":[
                {"Id":"person-1","Name":"Amy Adams","Role":"Louise","Type":"Actor","PrimaryImageTag":"amy"},
                {"Id":"person-2","Name":"Denis Villeneuve","Type":"Director"},
                {"Name":"Eric Heisserer","Type":"Writer"},
                {"Id":"person-3","Name":"Guest","Role":"Guest","Type":"GuestStar"},
                {"Id":"person-4","Name":"Composer","Type":"Composer"}
              ],
              "Chapters":[
                {"Name":"Opening","StartPositionTicks":0,"ImageTag":"ch0"},
                {"Name":"First Contact","StartPositionTicks":300000000,"ImageTag":"ch1"}
              ],
              "RemoteTrailers":[
                {"Name":"broken","Url":"javascript:bad"},
                {"Name":"Trailer","Url":"https://trailers.example.com/arrival"}
              ]
            }
            """
        )
        let next: JellyfinBaseItemDTO = try decode(
            """
            {"Id":"episode-next","Name":"Next","Type":"Episode","IndexNumber":3,"ParentIndexNumber":1}
            """
        )
        let detail = try XCTUnwrap(JellyfinCatalogMapper.detail(dto, nextEpisode: next, context: context))

        XCTAssertEqual(detail.tagline, "Why are they here?")
        XCTAssertEqual(detail.genres, ["Drama", "Science Fiction"])
        XCTAssertEqual(detail.studios, ["Paramount"])
        XCTAssertEqual(detail.cast.map(\.name), ["Amy Adams", "Guest"])
        XCTAssertEqual(detail.directors.map(\.name), ["Denis Villeneuve"])
        XCTAssertEqual(detail.writers.map(\.name), ["Eric Heisserer"])
        XCTAssertEqual(detail.cast.first?.titleTmdbId, 329_865)
        XCTAssertNotNil(detail.cast.first?.imageURL)
        XCTAssertEqual(detail.chapters.map(\.start), [0, 30])
        XCTAssertEqual(detail.chapters.first?.end, 30)
        XCTAssertEqual(detail.chapters.last?.end, 60)
        XCTAssertEqual(detail.trailerURL?.absoluteString, "https://trailers.example.com/arrival")
        XCTAssertEqual(detail.rating, 10)
        XCTAssertEqual(detail.nextEpisode?.ref.itemID, "episode-next")
        XCTAssertTrue(detail.mediaSources.isEmpty)
    }

    func testPagedMappingDropsMalformedItemsWithoutBreakingServerContinuation() throws {
        let response: JellyfinItemQueryResultDTO = try decode(
            """
            {
              "Items":[
                {"Id":"good","Name":"Movie","Type":"Movie"},
                {"Id":"  ","Name":"Malformed","Type":"Movie"}
              ],
              "StartIndex":0,
              "TotalRecordCount":4
            }
            """
        )
        let page = JellyfinCatalogMapper.pagedItems(
            response,
            requestedPage: Page(offset: 0, limit: 2),
            context: context
        )

        XCTAssertEqual(page.items.map(\.ref.itemID), ["good"])
        XCTAssertEqual(page.total, 4)
        XCTAssertEqual(page.nextPage, Page(offset: 2, limit: 2))
    }

    func testUnknownKindsMapWithoutFailingAndBlankContextIsRejected() throws {
        let dto: JellyfinBaseItemDTO = try decode(
            """
            {"Id":"future-1","Name":"Future","Type":"PluginVirtualItem"}
            """
        )

        XCTAssertEqual(JellyfinCatalogMapper.item(dto, context: context)?.kind, .unknown)
        XCTAssertNil(JellyfinCatalogContext(
            serverID: "  ",
            imageBuilder: JellyfinImageURLBuilder(
                serverURL: URL(string: "https://media.example.com")!,
                accessToken: "token"
            )
        ))
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
