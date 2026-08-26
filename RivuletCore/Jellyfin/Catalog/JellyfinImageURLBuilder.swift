// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum JellyfinImageType: String, Hashable, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
    case logo = "Logo"
    case chapter = "Chapter"
}

nonisolated struct JellyfinImageReferenceDTO: Hashable, Sendable {
    let itemID: String
    let type: JellyfinImageType
    let tag: String?
    let index: Int?

    init(itemID: String, type: JellyfinImageType, tag: String? = nil, index: Int? = nil) {
        self.itemID = itemID
        self.type = type
        self.tag = tag
        self.index = index
    }
}

/// Builds authenticated Jellyfin image URLs without leaking backend URL logic
/// into view models. Query items are assembled through `URLComponents` so tags,
/// tokens, and reverse-proxy subpaths remain correctly encoded.
nonisolated struct JellyfinImageURLBuilder: Hashable, Sendable {
    let serverURL: URL
    private let accessToken: String
    private let defaultMaxWidth: Int
    private let defaultQuality: Int

    init(serverURL: URL, accessToken: String, defaultMaxWidth: Int = 1_920, defaultQuality: Int = 90) {
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.defaultMaxWidth = defaultMaxWidth
        self.defaultQuality = min(100, max(1, defaultQuality))
    }

    func url(
        for image: JellyfinImageReferenceDTO?,
        maxWidth: Int? = nil,
        quality: Int? = nil
    ) -> URL? {
        guard let image else { return nil }
        let itemID = image.itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else { return nil }

        var url = serverURL
        url.appendPathComponent("Items")
        url.appendPathComponent(itemID)
        url.appendPathComponent("Images")
        url.appendPathComponent(image.type.rawValue)

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var queryItems: [URLQueryItem] = []
        if !accessToken.isEmpty {
            queryItems.append(URLQueryItem(name: "api_key", value: accessToken))
        }
        if let tag = image.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        let resolvedWidth = maxWidth ?? defaultMaxWidth
        if resolvedWidth > 0 {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(resolvedWidth)))
        }
        let resolvedQuality = min(100, max(1, quality ?? defaultQuality))
        queryItems.append(URLQueryItem(name: "quality", value: String(resolvedQuality)))
        if let index = image.index, index >= 0 {
            queryItems.append(URLQueryItem(name: "imageIndex", value: String(index)))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }
}
