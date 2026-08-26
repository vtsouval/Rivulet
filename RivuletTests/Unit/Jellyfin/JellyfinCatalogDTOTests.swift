// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

final class JellyfinCatalogDTOTests: XCTestCase {
    func testQueryResultDecodesCatalogAndToleratesUnknownImageEntries() throws {
        let response: JellyfinItemQueryResultDTO = try decode(
            """
            {
              "Items": [{
                "Id": "movie-1",
                "ServerId": "server-from-wire",
                "Name": "Arrival",
                "Type": "FutureMovieKind",
                "MediaType": "Video",
                "ProductionYear": 2016,
                "RunTimeTicks": 69600000000,
                "ImageTags": {
                  "Primary": "poster-tag",
                  "Logo": "logo-tag",
                  "FutureImage": 42,
                  "Thumb": null
                },
                "UserData": {
                  "Played": false,
                  "IsFavorite": true,
                  "PlaybackPositionTicks": 125000000,
                  "LastPlayedDate": "2026-08-26T12:34:56.1234567Z"
                }
              }],
              "TotalRecordCount": 31,
              "StartIndex": 20
            }
            """
        )

        XCTAssertEqual(response.items.count, 1)
        let item = try XCTUnwrap(response.items.first)
        XCTAssertEqual(item.id, "movie-1")
        XCTAssertEqual(item.type, "FutureMovieKind")
        XCTAssertEqual(item.runTimeTicks, 69_600_000_000)
        XCTAssertEqual(item.imageTags?.tag(for: .primary), "poster-tag")
        XCTAssertEqual(item.imageTags?.tag(for: .logo), "logo-tag")
        XCTAssertNil(item.imageTags?.tag(for: .thumb))
        XCTAssertEqual(item.userData?.playbackPositionTicks, 125_000_000)

        let continuation = response.continuation(for: Page(offset: 0, limit: 10))
        XCTAssertEqual(continuation.startIndex, 20)
        XCTAssertEqual(continuation.totalRecordCount, 31)
        XCTAssertEqual(continuation.nextPage, Page(offset: 21, limit: 10))
    }

    func testQueryResultMissingItemsProducesAnEmptyTerminalPage() throws {
        let response: JellyfinItemQueryResultDTO = try decode(
            """
            { "TotalRecordCount": 100, "StartIndex": 40 }
            """
        )

        XCTAssertTrue(response.items.isEmpty)
        XCTAssertNil(response.continuation(for: Page(offset: 40, limit: 20)).nextPage)
    }

    func testContinuationNeverMovesBackwardsWhenServerTotalIsStale() throws {
        let response: JellyfinItemQueryResultDTO = try decode(
            """
            {
              "Items": [{"Id":"1"},{"Id":"2"},{"Id":"3"}],
              "TotalRecordCount": 1,
              "StartIndex": 10
            }
            """
        )

        let continuation = response.continuation(for: Page(offset: 10, limit: 3))
        XCTAssertEqual(continuation.totalRecordCount, 13)
        XCTAssertNil(continuation.nextPage)
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
