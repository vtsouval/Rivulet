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

    /// Primary line for a native Continue Watching card. Episodes lead with
    /// their series so a row of mixed shows remains scannable; movies keep
    /// their own title.
    var continueWatchingTitle: String {
        if kind == .episode,
           let seriesTitle = seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !seriesTitle.isEmpty {
            return seriesTitle
        }
        return title
    }

    /// Episode name shown independently from its series. This avoids the
    /// ambiguous Jellyfin default where Continue Watching can say only
    /// "S1 E4" or only the episode name.
    var continueWatchingSubtitle: String? {
        guard kind == .episode else { return nil }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == continueWatchingTitle ? nil : value
    }

    /// Compact Apple-style hierarchy and remaining time, for example
    /// "S2, E4 · 18m left". Movies use only the remaining time.
    var continueWatchingProgressLabel: String? {
        let values = [episodeCoordinate, remainingTimeFormatted]
            .compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
        return values.isEmpty ? nil : values.joined(separator: "  ·  ")
    }

    /// Time remaining at the server-provided resume point. Keeping this a
    /// derivation of Jellyfin user data means every signed-in device presents
    /// the same value instead of maintaining a second local history.
    var remainingTimeFormatted: String? {
        guard let runtime, runtime > 0, userState.viewOffset > 0 else { return nil }
        let remaining = max(0, runtime - userState.viewOffset)
        guard remaining > 0 else { return nil }
        let minutes = max(1, Int(ceil(remaining / 60)))
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h left" : "\(hours)h \(remainder)m left"
        }
        return "\(minutes)m left"
    }

    /// "S01E03"-style label for episodes; nil for non-episodes.
    var episodeString: String? {
        guard kind == .episode,
              let s = seasonNumber,
              let e = episodeNumber else { return nil }
        return s == 0 ? "Special \(e)" : "S\(String(format: "%02d", s))E\(String(format: "%02d", e))"
    }

    /// Apple-style compact episode coordinates used in native detail and
    /// playback surfaces. Unlike `episodeString`, this remains useful when a
    /// backend supplies only one side of the hierarchy.
    var episodeCoordinate: String? {
        guard kind == .episode else { return nil }
        switch (seasonNumber, episodeNumber) {
        case let (season?, episode?): return season == 0 ? "Special \(episode)" : "S\(season), E\(episode)"
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
        // Jellyfin represents specials as index zero and some metadata agents
        // literally return "Season 0". The native UI should always use the
        // human label regardless of that server-side title.
        if seasonNumber == 0 { return "Specials" }
        if let seasonTitle = seasonTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !seasonTitle.isEmpty {
            return seasonTitle
        }
        guard let seasonNumber else { return nil }
        return seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    }

    /// Conservative Anime classification. Generic animation is intentionally
    /// not treated as Anime, so family films and western animation stay visible.
    var isAnime: Bool {
        let markers = (genres ?? []) + (tags ?? [])
        return markers.contains { value in
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "anime", "manga", "japanese animation", "anidb", "myanimelist": return true
            default: return false
            }
        }
    }
}

/// Stable, deduplicated search presentation shared by the provider and native
/// clients. Search results deliberately expose only title-level media: an
/// episode belongs inside its series page rather than competing with that
/// series in the global results rail.
struct MediaSearchSections: Equatable, Sendable {
    let movies: [MediaItem]
    let shows: [MediaItem]

    init(_ items: [MediaItem]) {
        var seenRefs = Set<MediaItemRef>()
        var seenTitles = Set<String>()
        var movies: [MediaItem] = []
        var shows: [MediaItem] = []
        for item in items where seenRefs.insert(item.ref).inserted {
            let title = item.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = "\(item.kind.rawValue)|\(title)|\(item.year.map(String.init) ?? "")"
            guard title.isEmpty || seenTitles.insert(identity).inserted else { continue }
            switch item.kind {
            case .movie: movies.append(item)
            case .show: shows.append(item)
            default: continue
            }
        }
        self.movies = movies
        self.shows = shows
    }

    var all: [MediaItem] { movies + shows }
    var isEmpty: Bool { movies.isEmpty && shows.isEmpty }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
