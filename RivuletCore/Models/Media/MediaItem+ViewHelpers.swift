// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItem+ViewHelpers.swift
//  Rivulet
//
//  Convenience computed properties used by views that display episode/season
//  cards. These are pure derivations from the fields already on MediaItem;
//  no network calls, no backend knowledge.
//

import Foundation

extension MediaItem {
    // MARK: - Watch State Helpers

    /// True when the item has been started but not finished.
    var isInProgress: Bool {
        WatchProgressPolicy.hasResumePoint(offsetSeconds: userState.viewOffset,
                                          runtimeSeconds: runtime)
    }

    /// True when the item has been fully watched (isPlayed flag from provider).
    var isWatched: Bool { userState.isPlayed }

    /// Fractional watch progress [0, 1], or nil if not started.
    var watchProgress: Double? {
        WatchProgressPolicy.progress(offsetSeconds: userState.viewOffset,
                                     runtimeSeconds: runtime)
    }

    // MARK: - Formatting

    /// Human-readable duration derived from `runtime` (seconds).
    var durationFormatted: String? {
        guard let runtime else { return nil }
        let totalMinutes = Int(runtime / 60)
        guard totalMinutes > 0 else { return nil }
        if totalMinutes >= 60 {
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(totalMinutes)m"
    }

    /// "S01E03"-style label for episodes; nil for non-episodes.
    var episodeString: String? {
        guard kind == .episode,
              let s = seasonNumber,
              let e = episodeNumber else { return nil }
        return "S\(String(format: "%02d", s))E\(String(format: "%02d", e))"
    }

    /// Apple-style compact episode coordinates used in native detail and
    /// playback surfaces. Unlike `episodeString`, this remains useful when a
    /// backend supplies only one side of the hierarchy.
    var episodeCoordinate: String? {
        guard kind == .episode else { return nil }
        switch (seasonNumber, episodeNumber) {
        case let (season?, episode?): return "S\(season), E\(episode)"
        case let (season?, nil): return season == 0 ? "Specials" : "Season \(season)"
        case let (nil, episode?): return "Episode \(episode)"
        case (nil, nil): return nil
        }
    }

    /// The title shown above an episode name in player chrome and detail
    /// pages, for example "Severance  ·  S2, E4".
    var episodeHierarchyTitle: String? {
        guard kind == .episode else { return nil }
        return [seriesTitle, episodeCoordinate]
            .compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "  ·  ")
            .nilIfEmpty
    }

    /// Season label that prefers the server's editorial name but falls back
    /// to a stable native label.
    var seasonDisplayTitle: String? {
        if let seasonTitle = seasonTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !seasonTitle.isEmpty {
            return seasonTitle
        }
        guard let seasonNumber else { return nil }
        return seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
