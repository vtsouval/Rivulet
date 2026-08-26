// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

final class JellyfinLiveTVMapperTests: XCTestCase {
    private let imageBuilder = JellyfinImageURLBuilder(
        serverURL: URL(string: "https://media.example/jellyfin")!,
        accessToken: "test-token"
    )

    func testChannelMapsStableIdentityAndArtwork() throws {
        let item = try decodeItem(#"""
        {
          "Id": "channel-7",
          "Name": "News HD",
          "Type": "TvChannel",
          "ChannelNumber": "7.1",
          "ChannelType": "TV",
          "Tags": ["News"],
          "ImageTags": { "Primary": "logo-tag" }
        }
        """#)

        let channel = try XCTUnwrap(JellyfinLiveTVMapper.channel(
            item,
            sourceID: "jellyfin:server-a",
            imageBuilder: imageBuilder
        ))

        XCTAssertEqual(channel.id, "jellyfin:jellyfin:server-a:channel-7")
        XCTAssertEqual(channel.sourceType, .jellyfin)
        XCTAssertEqual(channel.channelNumber, 7)
        XCTAssertEqual(channel.groupTitle, "News")
        XCTAssertTrue(channel.isHD)
        XCTAssertEqual(channel.tvgId, "channel-7")
        XCTAssertTrue(channel.logoURL?.absoluteString.contains("/Items/channel-7/Images/Primary") == true)
        XCTAssertTrue(channel.logoURL?.absoluteString.contains("api_key=test-token") == true)
    }

    func testProgramMapsScheduleEpisodeAndArtwork() throws {
        let item = try decodeItem(#"""
        {
          "Id": "program-1",
          "Name": "The Match",
          "EpisodeTitle": "Final",
          "Overview": "Championship coverage.",
          "ChannelId": "channel-7",
          "StartDate": "2026-08-26T18:30:00.0000000Z",
          "EndDate": "2026-08-26T20:30:00.0000000Z",
          "Genres": ["Sports"],
          "ParentIndexNumber": 2,
          "IndexNumber": 4,
          "IsRepeat": false,
          "ImageTags": { "Primary": "poster", "Thumb": "thumb" },
          "BackdropImageTags": ["backdrop"]
        }
        """#)

        let program = try XCTUnwrap(JellyfinLiveTVMapper.program(
            item,
            unifiedChannelID: "unified-7",
            imageBuilder: imageBuilder
        ))

        XCTAssertEqual(program.id, "program-1")
        XCTAssertEqual(program.channelId, "unified-7")
        XCTAssertEqual(program.title, "The Match")
        XCTAssertEqual(program.subtitle, "Final")
        XCTAssertEqual(program.category, "Sports")
        XCTAssertEqual(program.episodeNumber, "S02E04")
        XCTAssertTrue(program.isNew)
        XCTAssertEqual(program.durationMinutes, 120)
        XCTAssertTrue(program.posterURL?.absoluteString.contains("/Images/Primary") == true)
        XCTAssertTrue(program.landscapeURL?.absoluteString.contains("/Images/Backdrop") == true)
    }

    func testProgramRejectsMissingOrReversedSchedule() throws {
        let missing = try decodeItem(#"{"Id":"p","Name":"Missing date"}"#)
        XCTAssertNil(JellyfinLiveTVMapper.program(
            missing,
            unifiedChannelID: "channel",
            imageBuilder: imageBuilder
        ))

        let reversed = try decodeItem(#"""
        {
          "Id": "p",
          "Name": "Reversed",
          "StartDate": "2026-08-26T20:30:00Z",
          "EndDate": "2026-08-26T18:30:00Z"
        }
        """#)
        XCTAssertNil(JellyfinLiveTVMapper.program(
            reversed,
            unifiedChannelID: "channel",
            imageBuilder: imageBuilder
        ))
    }

    func testQueryEnvelopeToleratesMissingItems() throws {
        let value = try JSONDecoder().decode(
            JellyfinLiveTVQueryResultDTO.self,
            from: Data(#"{"TotalRecordCount":0}"#.utf8)
        )
        XCTAssertTrue(value.items.isEmpty)
        XCTAssertEqual(value.totalRecordCount, 0)
    }

    private func decodeItem(_ json: String) throws -> JellyfinLiveTVItemDTO {
        try JSONDecoder().decode(JellyfinLiveTVItemDTO.self, from: Data(json.utf8))
    }
}
