// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamInfo.swift
//  Rivulet
//
//  Result of provider.resolveStream(for:sourceID:). The chosen MediaSource
//  with streamURL materialized, plus per-session metadata for progress
//  reporting.
//

import Foundation

struct StreamInfo: Sendable {
    let source: MediaSource
    let playSessionID: String?
    /// false during HLS transcode where tracks come from the manifest, not from MediaSource fields.
    let trackInfoAvailable: Bool
    /// Headers the player must attach when loading `source.streamURL`.
    /// Jellyfin credentials belong here, never in the URL query string.
    let requestHeaders: [String: String]
    /// Identifies an opened live stream for progress and cleanup calls.
    let liveStreamID: String?
    /// The provider must close the live stream when playback ends or fails.
    let requiresLiveStreamClose: Bool

    init(
        source: MediaSource,
        playSessionID: String?,
        trackInfoAvailable: Bool,
        requestHeaders: [String: String] = [:],
        liveStreamID: String? = nil,
        requiresLiveStreamClose: Bool = false
    ) {
        self.source = source
        self.playSessionID = playSessionID
        self.trackInfoAvailable = trackInfoAvailable
        self.requestHeaders = requestHeaders
        self.liveStreamID = liveStreamID
        self.requiresLiveStreamClose = requiresLiveStreamClose
    }
}
