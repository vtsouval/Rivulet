// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

final class JellyfinImageURLBuilderTests: XCTestCase {
    func testImageURLPreservesProxyPathAndEncodesCredentialsAndTags() throws {
        let builder = JellyfinImageURLBuilder(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.com/jellyfin")),
            accessToken: "token +&?",
            defaultMaxWidth: 1_280,
            defaultQuality: 88
        )
        let url = try XCTUnwrap(builder.url(for: JellyfinImageReferenceDTO(
            itemID: "item-1",
            type: .backdrop,
            tag: "tag +&?",
            index: 2
        )))

        XCTAssertEqual(url.path, "/jellyfin/Items/item-1/Images/Backdrop")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(value("api_key", in: query), "token +&?")
        XCTAssertEqual(value("tag", in: query), "tag +&?")
        XCTAssertEqual(value("maxWidth", in: query), "1280")
        XCTAssertEqual(value("quality", in: query), "88")
        XCTAssertEqual(value("imageIndex", in: query), "2")
    }

    func testImageURLClampsQualityAndOmitsEmptyAuthentication() throws {
        let builder = JellyfinImageURLBuilder(
            serverURL: try XCTUnwrap(URL(string: "http://localhost:8096")),
            accessToken: "",
            defaultQuality: 200
        )
        let url = try XCTUnwrap(builder.url(
            for: JellyfinImageReferenceDTO(itemID: "person-1", type: .primary),
            maxWidth: 0,
            quality: -5
        ))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertNil(value("api_key", in: query))
        XCTAssertNil(value("maxWidth", in: query))
        XCTAssertEqual(value("quality", in: query), "1")
    }

    func testImageURLRejectsMissingReferenceAndBlankItemID() {
        let builder = JellyfinImageURLBuilder(
            serverURL: URL(string: "https://media.example.com")!,
            accessToken: "token"
        )

        XCTAssertNil(builder.url(for: nil))
        XCTAssertNil(builder.url(for: JellyfinImageReferenceDTO(itemID: "  ", type: .primary)))
    }

    private func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first(where: { $0.name == name })?.value
    }
}
