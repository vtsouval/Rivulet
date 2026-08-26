// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Normalizes a user-entered Jellyfin address into an API base URL.
///
/// Jellyfin is commonly hosted at either the origin (`http://nas:8096`) or a
/// reverse-proxy subpath (`https://example.com/jellyfin`). A copied web-client
/// URL may additionally end in `/web`, `/web/index.html`, a query, or a hash
/// route. Only that web-client suffix is removed; a legitimate proxy subpath is
/// preserved.
nonisolated enum JellyfinServerURL {
    static func normalize(_ value: String) throws -> URL {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw JellyfinAPIError.invalidServerURL
        }

        if !candidate.contains("://") {
            candidate = "http://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw JellyfinAPIError.invalidServerURL
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil

        var segments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if segments.last?.lowercased() == "index.html",
           segments.dropLast().last?.lowercased() == "web" {
            segments.removeLast(2)
        } else if segments.last?.lowercased() == "web" {
            segments.removeLast()
        }

        components.percentEncodedPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")

        guard let normalized = components.url else {
            throw JellyfinAPIError.invalidServerURL
        }
        return normalized
    }

    static func normalize(_ url: URL) throws -> URL {
        try normalize(url.absoluteString)
    }
}
