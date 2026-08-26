// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Stable identifiers and track choices carried by every Jellyfin playback
/// report. Keeping this context immutable prevents a source switch from
/// accidentally reporting progress against the previous media source.
nonisolated struct JellyfinPlaybackReportContext: Equatable, Sendable {
    let itemID: String
    let mediaSourceID: String?
    let playSessionID: String?
    let liveStreamID: String?
    let delivery: JellyfinPlaybackDelivery
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let canSeek: Bool

    init(
        itemID: String,
        mediaSourceID: String? = nil,
        playSessionID: String? = nil,
        liveStreamID: String? = nil,
        delivery: JellyfinPlaybackDelivery,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        canSeek: Bool = true
    ) {
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.liveStreamID = liveStreamID
        self.delivery = delivery
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.canSeek = canSeek
    }
}

/// Body for `POST /Sessions/Playing`.
nonisolated struct JellyfinPlaybackStartRequest: Encodable, Sendable {
    private let state: JellyfinPlaybackStatePayload

    init(
        context: JellyfinPlaybackReportContext,
        position: TimeInterval,
        isMuted: Bool = false,
        volumeLevel: Int? = nil
    ) {
        state = JellyfinPlaybackStatePayload(
            context: context,
            position: position,
            isPaused: false,
            isMuted: isMuted,
            volumeLevel: volumeLevel
        )
    }

    func encode(to encoder: Encoder) throws { try state.encode(to: encoder) }
}

/// Body for `POST /Sessions/Playing/Progress`. Pause and resume are progress
/// reports whose `IsPaused` state changes; Jellyfin has no separate pause DTO.
nonisolated struct JellyfinPlaybackProgressRequest: Encodable, Sendable {
    private let state: JellyfinPlaybackStatePayload

    init(
        context: JellyfinPlaybackReportContext,
        position: TimeInterval,
        isPaused: Bool,
        isMuted: Bool = false,
        volumeLevel: Int? = nil
    ) {
        state = JellyfinPlaybackStatePayload(
            context: context,
            position: position,
            isPaused: isPaused,
            isMuted: isMuted,
            volumeLevel: volumeLevel
        )
    }

    static func playing(
        context: JellyfinPlaybackReportContext,
        position: TimeInterval,
        isMuted: Bool = false,
        volumeLevel: Int? = nil
    ) -> Self {
        Self(
            context: context,
            position: position,
            isPaused: false,
            isMuted: isMuted,
            volumeLevel: volumeLevel
        )
    }

    static func paused(
        context: JellyfinPlaybackReportContext,
        position: TimeInterval,
        isMuted: Bool = false,
        volumeLevel: Int? = nil
    ) -> Self {
        Self(
            context: context,
            position: position,
            isPaused: true,
            isMuted: isMuted,
            volumeLevel: volumeLevel
        )
    }

    func encode(to encoder: Encoder) throws { try state.encode(to: encoder) }
}

/// Body for `POST /Sessions/Playing/Stopped`.
nonisolated struct JellyfinPlaybackStopRequest: Encodable, Sendable {
    let itemID: String
    let mediaSourceID: String?
    let playSessionID: String?
    let liveStreamID: String?
    let positionTicks: Int64
    let failed: Bool

    init(context: JellyfinPlaybackReportContext, position: TimeInterval, failed: Bool = false) {
        itemID = context.itemID
        mediaSourceID = context.mediaSourceID
        playSessionID = context.playSessionID
        liveStreamID = context.liveStreamID
        positionTicks = JellyfinTicks.fromSeconds(position)
        self.failed = failed
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case liveStreamID = "LiveStreamId"
        case positionTicks = "PositionTicks"
        case failed = "Failed"
    }
}

nonisolated private struct JellyfinPlaybackStatePayload: Encodable, Sendable {
    let itemID: String
    let mediaSourceID: String?
    let playSessionID: String?
    let liveStreamID: String?
    let playMethod: JellyfinPlaybackDelivery
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let positionTicks: Int64
    let canSeek: Bool
    let isPaused: Bool
    let isMuted: Bool
    let volumeLevel: Int?

    init(
        context: JellyfinPlaybackReportContext,
        position: TimeInterval,
        isPaused: Bool,
        isMuted: Bool,
        volumeLevel: Int?
    ) {
        itemID = context.itemID
        mediaSourceID = context.mediaSourceID
        playSessionID = context.playSessionID
        liveStreamID = context.liveStreamID
        playMethod = context.delivery
        audioStreamIndex = context.audioStreamIndex
        subtitleStreamIndex = context.subtitleStreamIndex
        positionTicks = JellyfinTicks.fromSeconds(position)
        canSeek = context.canSeek
        self.isPaused = isPaused
        self.isMuted = isMuted
        self.volumeLevel = volumeLevel.map { min(100, max(0, $0)) }
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case liveStreamID = "LiveStreamId"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case positionTicks = "PositionTicks"
        case canSeek = "CanSeek"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case volumeLevel = "VolumeLevel"
    }
}
