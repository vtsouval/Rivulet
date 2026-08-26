// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A small non-secret snapshot that lets the signed-in shell paint immediately
/// after launch. Authentication remains exclusively in Keychain; this file
/// contains only library names, card metadata and image URLs.
struct IOSJellyfinSnapshot: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let updatedAt: Date
    let libraries: [MediaLibrary]
    let homeHubs: [MediaHub]
    let catalogs: [String: [MediaItem]]
}

@MainActor
final class IOSJellyfinSnapshotCache {
    static let shared = IOSJellyfinSnapshotCache()

    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }()
    private let decoder = JSONDecoder()

    private init() {}

    func load(server: URL, userID: String) -> IOSJellyfinSnapshot? {
        let url = fileURL(server: server, userID: userID)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(IOSJellyfinSnapshot.self, from: data),
              snapshot.version == IOSJellyfinSnapshot.currentVersion else { return nil }
        return snapshot
    }

    func save(_ snapshot: IOSJellyfinSnapshot, server: URL, userID: String) {
        guard let data = try? encoder.encode(snapshot) else { return }
        let folder = cacheFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: fileURL(server: server, userID: userID), options: [.atomic])
    }

    func remove(server: URL, userID: String) {
        try? FileManager.default.removeItem(at: fileURL(server: server, userID: userID))
    }

    func totalBytes() -> Int64 {
        guard let values = try? FileManager.default.contentsOfDirectory(
            at: cacheFolder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return values.reduce(into: 0) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private var cacheFolder: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("JellyfinSnapshots", isDirectory: true)
    }

    private func fileURL(server: URL, userID: String) -> URL {
        let identity = "\(server.absoluteString.lowercased())|\(userID.lowercased())"
        let digest = identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return cacheFolder.appendingPathComponent(String(digest, radix: 16) + ".json")
    }
}
