// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Jellyfin's three useful playback decisions, named in player-facing terms.
/// `remux` corresponds to Jellyfin's `DirectStream` play method.
nonisolated enum JellyfinPlaybackDelivery: String, Codable, Hashable, Sendable {
    case directPlay = "DirectPlay"
    case remux = "DirectStream"
    case transcode = "Transcode"

    var directnessRank: Int {
        switch self {
        case .directPlay: return 0
        case .remux: return 1
        case .transcode: return 2
        }
    }
}

nonisolated struct JellyfinSourceSelectionPolicy: Equatable, Sendable {
    /// A source explicitly chosen by the user always wins when it is playable.
    let preferredSourceID: String?
    /// Desired output height. A source below the target is preferred to one
    /// above it by an equal distance, avoiding an unnecessary 4K transcode
    /// when the profile asks for 1080p.
    let preferredVideoHeight: Int?
    /// Optional policy cap in addition to the device/server negotiation cap.
    let maxBitrate: Int?
    /// Direct play/remux are considered before small quality differences.
    let prioritizesDirectness: Bool

    init(
        preferredSourceID: String? = nil,
        preferredVideoHeight: Int? = nil,
        maxBitrate: Int? = nil,
        prioritizesDirectness: Bool = true
    ) {
        self.preferredSourceID = preferredSourceID
        self.preferredVideoHeight = preferredVideoHeight
        self.maxBitrate = maxBitrate
        self.prioritizesDirectness = prioritizesDirectness
    }
}

nonisolated struct JellyfinRankedMediaSource: Sendable {
    let source: JellyfinMediaSourceInfo
    let delivery: JellyfinPlaybackDelivery
}

nonisolated enum JellyfinSourceSelector {
    static func best(
        from sources: [JellyfinMediaSourceInfo],
        capabilities: JellyfinPlaybackCapabilities,
        policy: JellyfinSourceSelectionPolicy = JellyfinSourceSelectionPolicy()
    ) -> JellyfinRankedMediaSource? {
        ranked(from: sources, capabilities: capabilities, policy: policy).first
    }

    static func ranked(
        from sources: [JellyfinMediaSourceInfo],
        capabilities: JellyfinPlaybackCapabilities,
        policy: JellyfinSourceSelectionPolicy = JellyfinSourceSelectionPolicy()
    ) -> [JellyfinRankedMediaSource] {
        sources.compactMap { source -> Candidate? in
            guard let delivery = bestDelivery(for: source, capabilities: capabilities, policy: policy) else {
                return nil
            }
            return Candidate(
                ranked: JellyfinRankedMediaSource(source: source, delivery: delivery),
                rank: Rank(source: source, delivery: delivery, capabilities: capabilities, policy: policy)
            )
        }
        .sorted { $0.rank < $1.rank }
        .map(\.ranked)
    }

    static func supportedDeliveries(
        for source: JellyfinMediaSourceInfo,
        capabilities: JellyfinPlaybackCapabilities
    ) -> [JellyfinPlaybackDelivery] {
        let exceedsFixedDeliveryLimits = exceedsLimits(source, capabilities: capabilities, policyMaxBitrate: nil)
        var deliveries: [JellyfinPlaybackDelivery] = []

        if capabilities.allowsDirectPlay,
           source.supportsDirectPlay == true,
           !exceedsFixedDeliveryLimits {
            deliveries.append(.directPlay)
        }
        if capabilities.allowsRemux,
           source.supportsDirectStream == true,
           !exceedsFixedDeliveryLimits {
            deliveries.append(.remux)
        }
        if capabilities.allowsTranscoding,
           source.supportsTranscoding == true || source.transcodingURL != nil {
            deliveries.append(.transcode)
        }
        return deliveries
    }

    private static func bestDelivery(
        for source: JellyfinMediaSourceInfo,
        capabilities: JellyfinPlaybackCapabilities,
        policy: JellyfinSourceSelectionPolicy
    ) -> JellyfinPlaybackDelivery? {
        let exceedsPolicyLimits = exceedsLimits(
            source,
            capabilities: capabilities,
            policyMaxBitrate: policy.maxBitrate
        )

        if !exceedsPolicyLimits,
           capabilities.allowsDirectPlay,
           source.supportsDirectPlay == true {
            return .directPlay
        }
        if !exceedsPolicyLimits,
           capabilities.allowsRemux,
           source.supportsDirectStream == true {
            return .remux
        }
        if capabilities.allowsTranscoding,
           source.supportsTranscoding == true || source.transcodingURL != nil {
            return .transcode
        }
        return nil
    }

    private static func exceedsLimits(
        _ source: JellyfinMediaSourceInfo,
        capabilities: JellyfinPlaybackCapabilities,
        policyMaxBitrate: Int?
    ) -> Bool {
        if let maxWidth = capabilities.maxVideoWidth,
           let width = source.videoWidth,
           width > maxWidth {
            return true
        }
        if let maxHeight = capabilities.maxVideoHeight,
           let height = source.videoHeight,
           height > maxHeight {
            return true
        }
        let bitrateLimit = [capabilities.maxStreamingBitrate, policyMaxBitrate]
            .compactMap { $0 }
            .min()
        if let bitrateLimit,
           let bitrate = source.bitrate,
           bitrate > bitrateLimit {
            return true
        }
        return false
    }
}

private extension JellyfinSourceSelector {
    struct Candidate {
        let ranked: JellyfinRankedMediaSource
        let rank: Rank
    }

    struct Rank: Comparable {
        let explicitChoice: Int
        let primaryPreference: Int
        let secondaryPreference: Int
        let bitratePenalty: Int64
        let stableID: String

        init(
            source: JellyfinMediaSourceInfo,
            delivery: JellyfinPlaybackDelivery,
            capabilities: JellyfinPlaybackCapabilities,
            policy: JellyfinSourceSelectionPolicy
        ) {
            explicitChoice = source.id == policy.preferredSourceID ? 0 : 1

            let qualityPenalty: Int
            if let preferredHeight = policy.preferredVideoHeight {
                if let height = source.videoHeight {
                    let distance = abs(height - preferredHeight)
                    // At equal distance, prefer the source below the target so
                    // a 1080p profile does not unnecessarily negotiate 4K.
                    qualityPenalty = distance * 2 + (height > preferredHeight ? 1 : 0)
                } else {
                    qualityPenalty = Int.max / 4
                }
            } else if let height = source.videoHeight {
                // Highest known resolution first when no target was supplied.
                qualityPenalty = max(0, 16_384 - min(height, 16_384))
            } else {
                qualityPenalty = Int.max / 4
            }

            if policy.prioritizesDirectness {
                primaryPreference = delivery.directnessRank
                secondaryPreference = qualityPenalty
            } else {
                primaryPreference = qualityPenalty
                secondaryPreference = delivery.directnessRank
            }

            let bitrateLimit = [capabilities.maxStreamingBitrate, policy.maxBitrate]
                .compactMap { $0 }
                .min()
            if let bitrate = source.bitrate {
                if let bitrateLimit, bitrate > bitrateLimit {
                    bitratePenalty = Int64(bitrate - bitrateLimit) + 1_000_000_000
                } else {
                    // Prefer the richer source only after directness and
                    // resolution have been decided.
                    bitratePenalty = -Int64(bitrate)
                }
            } else {
                bitratePenalty = Int64.max / 4
            }

            // A stable final key makes ranking deterministic even when
            // Jellyfin or Gelato returns sources in a different order.
            stableID = source.id ?? source.name ?? source.path ?? "~"
        }

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.explicitChoice != rhs.explicitChoice { return lhs.explicitChoice < rhs.explicitChoice }
            if lhs.primaryPreference != rhs.primaryPreference { return lhs.primaryPreference < rhs.primaryPreference }
            if lhs.secondaryPreference != rhs.secondaryPreference { return lhs.secondaryPreference < rhs.secondaryPreference }
            if lhs.bitratePenalty != rhs.bitratePenalty { return lhs.bitratePenalty < rhs.bitratePenalty }
            return lhs.stableID < rhs.stableID
        }
    }
}
