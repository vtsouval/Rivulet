// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Short-lived handoff between detail loading and playback. Jellyfin's
/// `PlaybackInfo` response is already needed to render source choices; reusing
/// that response avoids a second negotiation when the user immediately presses
/// Play. Entries are single-use because a `PlaySessionId` identifies one
/// playback attempt.
actor JellyfinPlaybackPreparationCache {
    struct Entry: Sendable {
        let response: JellyfinPlaybackInfoResponse
        let resumePosition: TimeInterval
        let createdAt: Date
    }

    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]

    init(lifetime: TimeInterval = 30) {
        self.lifetime = max(1, lifetime)
    }

    func store(
        _ response: JellyfinPlaybackInfoResponse,
        itemID: String,
        resumePosition: TimeInterval,
        now: Date = Date()
    ) {
        entries = entries.filter { now.timeIntervalSince($0.value.createdAt) <= lifetime }
        let normalizedPosition = resumePosition.isFinite ? max(0, resumePosition) : 0
        entries[itemID] = Entry(
            response: response,
            resumePosition: normalizedPosition,
            createdAt: now
        )
    }

    func take(itemID: String, now: Date = Date()) -> Entry? {
        guard let entry = entries.removeValue(forKey: itemID),
              now.timeIntervalSince(entry.createdAt) <= lifetime else {
            return nil
        }
        return entry
    }

    func takeResumePosition(itemID: String, now: Date = Date()) -> TimeInterval? {
        take(itemID: itemID, now: now)?.resumePosition
    }
}
