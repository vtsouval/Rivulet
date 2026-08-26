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
            // A missing scheme must never silently downgrade credentials to
            // cleartext. Local HTTP remains available when the user types it
            // explicitly for a private LAN Jellyfin instance.
            candidate = "https://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw JellyfinAPIError.invalidServerURL
        }

        if scheme == "http", let host = components.host,
           !allowsInsecureHTTP(to: host) {
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

    /// Cleartext is restricted to loopback, link-local and RFC1918/ULA hosts.
    /// Public and DNS-hosted servers must use HTTPS because every Jellyfin API
    /// request carries an access token after authentication.
    private static func allowsInsecureHTTP(to host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized.hasSuffix(".local") || normalized == "::1" {
            return true
        }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true
        }

        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}
