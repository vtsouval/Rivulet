// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

final class JellyfinPlaybackPreparationCacheTests: XCTestCase {
    func test_entryIsSingleUseAndCarriesResumePosition() async throws {
        let cache = JellyfinPlaybackPreparationCache(lifetime: 30)
        let response = try response(playSessionID: "session-1")
        let now = Date(timeIntervalSince1970: 100)
        await cache.store(response, itemID: "item", resumePosition: 42.5, now: now)

        let entry = await cache.take(itemID: "item", now: now.addingTimeInterval(1))
        XCTAssertEqual(entry?.response.playSessionID, "session-1")
        XCTAssertEqual(entry?.resumePosition, 42.5)
        let second = await cache.take(itemID: "item", now: now.addingTimeInterval(2))
        XCTAssertNil(second)
    }

    func test_expiredEntryCannotSupplyResponseOrResumePosition() async throws {
        let cache = JellyfinPlaybackPreparationCache(lifetime: 2)
        let now = Date(timeIntervalSince1970: 100)
        await cache.store(
            try response(playSessionID: "expired"),
            itemID: "item",
            resumePosition: 10,
            now: now
        )

        let resume = await cache.takeResumePosition(
            itemID: "item",
            now: now.addingTimeInterval(3)
        )
        XCTAssertNil(resume)
    }

    private func response(playSessionID: String) throws -> JellyfinPlaybackInfoResponse {
        let json = #"{"PlaySessionId":"\#(playSessionID)","MediaSources":[]}"#
        return try JSONDecoder().decode(JellyfinPlaybackInfoResponse.self, from: Data(json.utf8))
    }
}
