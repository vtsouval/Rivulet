// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class JellyfinSyncPlayTests: XCTestCase {
    func test_decodesScheduledSeekCommandWithJellyfinTicks() throws {
        let event = JellyfinSyncPlayClient.decodeEvent(
            Data(#"{"MessageType":"SyncPlayCommand","Data":{"Command":"Seek","PositionTicks":125000000,"When":"2026-08-26T19:30:15.250Z","EmittedAt":"2026-08-26T19:30:14Z","PlaylistItemId":"playlist-1"}}"#.utf8)
        )

        guard case .command(let command) = try XCTUnwrap(event) else {
            return XCTFail("Expected SyncPlay command")
        }
        XCTAssertEqual(command.kind, .seek)
        XCTAssertEqual(command.position, 12.5)
        XCTAssertEqual(command.playlistItemID, "playlist-1")
        XCTAssertNotNil(command.executeAt)
        XCTAssertNotNil(command.emittedAt)
    }

    func test_decodesPlayQueueAndCurrentPlaylistIdentity() throws {
        let event = JellyfinSyncPlayClient.decodeEvent(
            Data(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"Type":"PlayQueue","Data":{"Playlist":[{"ItemId":"episode-1","PlaylistItemId":"queue-1"},{"ItemId":"episode-2","PlaylistItemId":"queue-2"}],"PlayingItemIndex":1,"StartPositionTicks":"427500000","IsPlaying":true}}}"#.utf8)
        )

        guard case .queueChanged(let queue) = try XCTUnwrap(event) else {
            return XCTFail("Expected SyncPlay queue")
        }
        XCTAssertEqual(queue.items.count, 2)
        XCTAssertEqual(queue.current?.itemID, "episode-2")
        XCTAssertEqual(queue.current?.playlistItemID, "queue-2")
        XCTAssertEqual(queue.startPosition, 42.75)
        XCTAssertTrue(queue.isPlaying)
    }

    func test_decodesGroupAndParticipantUpdates() throws {
        let joined = JellyfinSyncPlayClient.decodeEvent(
            Data(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"Type":"GroupJoined","Data":{"GroupId":"group-1","GroupName":"Friday Night","Participants":["Vasilis","Apostolis"],"State":"Paused"}}}"#.utf8)
        )
        guard case .joined(let group) = try XCTUnwrap(joined) else {
            return XCTFail("Expected joined event")
        }
        XCTAssertEqual(group.id, "group-1")
        XCTAssertEqual(group.name, "Friday Night")
        XCTAssertEqual(group.participants, ["Vasilis", "Apostolis"])
        XCTAssertEqual(group.state, .paused)

        let participant = JellyfinSyncPlayClient.decodeEvent(
            Data(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"Type":"UserJoined","Data":"Guest"}}"#.utf8)
        )
        XCTAssertEqual(participant, .participantJoined("Guest"))
    }

    func test_rejectsUnknownOrMalformedSocketMessages() {
        XCTAssertNil(JellyfinSyncPlayClient.decodeEvent(Data(#"{"MessageType":"KeepAlive"}"#.utf8)))
        XCTAssertNil(JellyfinSyncPlayClient.decodeEvent(Data("not-json".utf8)))
    }
}
