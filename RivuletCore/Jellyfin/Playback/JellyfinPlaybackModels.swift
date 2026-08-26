// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The capabilities Rivulet asks Jellyfin to negotiate for a playback session.
///
/// This is deliberately separate from the eventual player route. Jellyfin is
/// authoritative about what each media source can do; the client only declares
/// which delivery families it is prepared to consume.
nonisolated struct JellyfinPlaybackCapabilities: Equatable, Sendable {
    var allowsDirectPlay: Bool
    var allowsRemux: Bool
    var allowsTranscoding: Bool
    var allowsVideoStreamCopy: Bool
    var allowsAudioStreamCopy: Bool
    var maxStreamingBitrate: Int?
    var maxVideoWidth: Int?
    var maxVideoHeight: Int?
    var maxAudioChannels: Int?

    init(
        allowsDirectPlay: Bool = true,
        allowsRemux: Bool = true,
        allowsTranscoding: Bool = true,
        allowsVideoStreamCopy: Bool = true,
        allowsAudioStreamCopy: Bool = true,
        maxStreamingBitrate: Int? = nil,
        maxVideoWidth: Int? = nil,
        maxVideoHeight: Int? = nil,
        maxAudioChannels: Int? = nil
    ) {
        self.allowsDirectPlay = allowsDirectPlay
        self.allowsRemux = allowsRemux
        self.allowsTranscoding = allowsTranscoding
        self.allowsVideoStreamCopy = allowsVideoStreamCopy
        self.allowsAudioStreamCopy = allowsAudioStreamCopy
        self.maxStreamingBitrate = maxStreamingBitrate
        self.maxVideoWidth = maxVideoWidth
        self.maxVideoHeight = maxVideoHeight
        self.maxAudioChannels = maxAudioChannels
    }
}

/// Minimal Jellyfin device profile payload required by PlaybackInfo.
/// Additional profile detail can be added without changing the negotiation or
/// source-selection types in this folder.
nonisolated struct JellyfinDeviceProfile: Encodable, Sendable {
    let name: String?
    let maxStreamingBitrate: Int?
    let maxStaticBitrate: Int?
    let directPlayProfiles: [JellyfinDirectPlayProfile]
    let transcodingProfiles: [JellyfinTranscodingProfile]
    let subtitleProfiles: [JellyfinSubtitleProfile]

    init(
        name: String? = nil,
        maxStreamingBitrate: Int? = nil,
        maxStaticBitrate: Int? = nil,
        directPlayProfiles: [JellyfinDirectPlayProfile] = [],
        transcodingProfiles: [JellyfinTranscodingProfile] = [],
        subtitleProfiles: [JellyfinSubtitleProfile] = []
    ) {
        self.name = name
        self.maxStreamingBitrate = maxStreamingBitrate
        self.maxStaticBitrate = maxStaticBitrate
        self.directPlayProfiles = directPlayProfiles
        self.transcodingProfiles = transcodingProfiles
        self.subtitleProfiles = subtitleProfiles
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }
}

nonisolated enum JellyfinProfileType: String, Encodable, Sendable {
    case audio = "Audio"
    case video = "Video"
}

nonisolated struct JellyfinDirectPlayProfile: Encodable, Sendable {
    let container: String?
    let audioCodec: String?
    let videoCodec: String?
    let type: JellyfinProfileType

    init(container: String? = nil, audioCodec: String? = nil, videoCodec: String? = nil,
         type: JellyfinProfileType) {
        self.container = container
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case audioCodec = "AudioCodec"
        case videoCodec = "VideoCodec"
        case type = "Type"
    }
}

nonisolated struct JellyfinTranscodingProfile: Encodable, Sendable {
    let container: String
    let type: JellyfinProfileType
    let videoCodec: String?
    let audioCodec: String?
    let `protocol`: String?
    let context: String?
    let copyTimestamps: Bool?
    let enableSubtitlesInManifest: Bool?

    init(
        container: String,
        type: JellyfinProfileType,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        protocol: String? = nil,
        context: String? = "Streaming",
        copyTimestamps: Bool? = true,
        enableSubtitlesInManifest: Bool? = true
    ) {
        self.container = container
        self.type = type
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.protocol = `protocol`
        self.context = context
        self.copyTimestamps = copyTimestamps
        self.enableSubtitlesInManifest = enableSubtitlesInManifest
    }

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case `protocol` = "Protocol"
        case context = "Context"
        case copyTimestamps = "CopyTimestamps"
        case enableSubtitlesInManifest = "EnableSubtitlesInManifest"
    }
}

nonisolated struct JellyfinSubtitleProfile: Encodable, Sendable {
    let format: String
    let method: String
    let didlMode: String?
    let language: String?
    let container: String?

    init(format: String, method: String, didlMode: String? = nil,
         language: String? = nil, container: String? = nil) {
        self.format = format
        self.method = method
        self.didlMode = didlMode
        self.language = language
        self.container = container
    }

    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
        case didlMode = "DidlMode"
        case language = "Language"
        case container = "Container"
    }
}

/// `POST /Items/{itemId}/PlaybackInfo` request body.
nonisolated struct JellyfinPlaybackInfoRequest: Encodable, Sendable {
    let userID: String?
    let startTimeTicks: Int64?
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let mediaSourceID: String?
    let liveStreamID: String?
    let autoOpenLiveStream: Bool?
    let maxStreamingBitrate: Int?
    let maxAudioChannels: Int?
    let enableDirectPlay: Bool
    let enableDirectStream: Bool
    let enableTranscoding: Bool
    let allowVideoStreamCopy: Bool
    let allowAudioStreamCopy: Bool
    let alwaysBurnInSubtitleWhenTranscoding: Bool?
    let deviceProfile: JellyfinDeviceProfile?

    init(
        userID: String? = nil,
        startPosition: TimeInterval? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        mediaSourceID: String? = nil,
        liveStreamID: String? = nil,
        autoOpenLiveStream: Bool? = nil,
        capabilities: JellyfinPlaybackCapabilities = JellyfinPlaybackCapabilities(),
        alwaysBurnInSubtitleWhenTranscoding: Bool? = nil,
        deviceProfile: JellyfinDeviceProfile? = nil
    ) {
        self.userID = userID
        self.startTimeTicks = startPosition.map(JellyfinTicks.fromSeconds)
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.mediaSourceID = mediaSourceID
        self.liveStreamID = liveStreamID
        self.autoOpenLiveStream = autoOpenLiveStream
        self.maxStreamingBitrate = capabilities.maxStreamingBitrate
        self.maxAudioChannels = capabilities.maxAudioChannels
        self.enableDirectPlay = capabilities.allowsDirectPlay
        self.enableDirectStream = capabilities.allowsRemux
        self.enableTranscoding = capabilities.allowsTranscoding
        self.allowVideoStreamCopy = capabilities.allowsVideoStreamCopy
        self.allowAudioStreamCopy = capabilities.allowsAudioStreamCopy
        self.alwaysBurnInSubtitleWhenTranscoding = alwaysBurnInSubtitleWhenTranscoding
        self.deviceProfile = deviceProfile
    }

    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case startTimeTicks = "StartTimeTicks"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case mediaSourceID = "MediaSourceId"
        case liveStreamID = "LiveStreamId"
        case autoOpenLiveStream = "AutoOpenLiveStream"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxAudioChannels = "MaxAudioChannels"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case alwaysBurnInSubtitleWhenTranscoding = "AlwaysBurnInSubtitleWhenTranscoding"
        case deviceProfile = "DeviceProfile"
    }
}

/// `PlaybackInfoResponse` returned by Jellyfin.
nonisolated struct JellyfinPlaybackInfoResponse: Decodable, Sendable {
    let mediaSources: [JellyfinMediaSourceInfo]
    let playSessionID: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mediaSources = try values.decodeIfPresent([JellyfinMediaSourceInfo].self, forKey: .mediaSources) ?? []
        playSessionID = try values.decodeIfPresent(String.self, forKey: .playSessionID)
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

nonisolated enum JellyfinMediaStreamKind: Hashable, Sendable {
    case audio
    case video
    case subtitle
    case embeddedImage
    case data
    case lyric
    case other(String)
}

nonisolated extension JellyfinMediaStreamKind: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value.lowercased() {
        case "audio": self = .audio
        case "video": self = .video
        case "subtitle": self = .subtitle
        case "embeddedimage": self = .embeddedImage
        case "data": self = .data
        case "lyric": self = .lyric
        default: self = .other(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        let value: String
        switch self {
        case .audio: value = "Audio"
        case .video: value = "Video"
        case .subtitle: value = "Subtitle"
        case .embeddedImage: value = "EmbeddedImage"
        case .data: value = "Data"
        case .lyric: value = "Lyric"
        case .other(let raw): value = raw
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

nonisolated struct JellyfinMediaStream: Codable, Hashable, Sendable {
    let index: Int?
    let type: JellyfinMediaStreamKind?
    let codec: String?
    let codecTag: String?
    let profile: String?
    let level: Double?
    let language: String?
    let title: String?
    let displayTitle: String?
    let path: String?
    let deliveryMethod: String?
    let deliveryURL: String?
    let isExternal: Bool?
    let isExternalURL: Bool?
    let supportsExternalStream: Bool?
    let isTextSubtitleStream: Bool?
    let isDefault: Bool?
    let isForced: Bool?
    let isHearingImpaired: Bool?
    let isInterlaced: Bool?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let bitDepth: Int?
    let averageFrameRate: Double?
    let realFrameRate: Double?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let videoRange: String?
    let videoRangeType: String?
    let colorSpace: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let dvProfile: Int?
    let hdr10PlusPresent: Bool?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case codecTag = "CodecTag"
        case profile = "Profile"
        case level = "Level"
        case language = "Language"
        case title = "Title"
        case displayTitle = "DisplayTitle"
        case path = "Path"
        case deliveryMethod = "DeliveryMethod"
        case deliveryURL = "DeliveryUrl"
        case isExternal = "IsExternal"
        case isExternalURL = "IsExternalUrl"
        case supportsExternalStream = "SupportsExternalStream"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isHearingImpaired = "IsHearingImpaired"
        case isInterlaced = "IsInterlaced"
        case width = "Width"
        case height = "Height"
        case bitRate = "BitRate"
        case bitDepth = "BitDepth"
        case averageFrameRate = "AverageFrameRate"
        case realFrameRate = "RealFrameRate"
        case channels = "Channels"
        case channelLayout = "ChannelLayout"
        case sampleRate = "SampleRate"
        case videoRange = "VideoRange"
        case videoRangeType = "VideoRangeType"
        case colorSpace = "ColorSpace"
        case colorTransfer = "ColorTransfer"
        case colorPrimaries = "ColorPrimaries"
        case dvProfile = "DvProfile"
        case hdr10PlusPresent = "Hdr10PlusPresentFlag"
    }
}

nonisolated struct JellyfinMediaSourceInfo: Decodable, Sendable {
    let id: String?
    let name: String?
    let path: String?
    let `protocol`: String?
    let type: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let runTimeTicks: Int64?
    let isRemote: Bool?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let isInfiniteStream: Bool?
    let requiresOpening: Bool?
    let openToken: String?
    let requiresClosing: Bool?
    let liveStreamID: String?
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    let mediaStreams: [JellyfinMediaStream]
    let requiredHTTPHeaders: [String: String]
    let transcodingURL: String?
    let transcodingContainer: String?
    let transcodingSubProtocol: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case `protocol` = "Protocol"
        case type = "Type"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case runTimeTicks = "RunTimeTicks"
        case isRemote = "IsRemote"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case isInfiniteStream = "IsInfiniteStream"
        case requiresOpening = "RequiresOpening"
        case openToken = "OpenToken"
        case requiresClosing = "RequiresClosing"
        case liveStreamID = "LiveStreamId"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case mediaStreams = "MediaStreams"
        case requiredHTTPHeaders = "RequiredHttpHeaders"
        case transcodingURL = "TranscodingUrl"
        case transcodingContainer = "TranscodingContainer"
        case transcodingSubProtocol = "TranscodingSubProtocol"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        `protocol` = try values.decodeIfPresent(String.self, forKey: .protocol)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        container = try values.decodeIfPresent(String.self, forKey: .container)
        size = try values.decodeIfPresent(Int64.self, forKey: .size)
        bitrate = try values.decodeIfPresent(Int.self, forKey: .bitrate)
        runTimeTicks = try values.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        isRemote = try values.decodeIfPresent(Bool.self, forKey: .isRemote)
        supportsDirectPlay = try values.decodeIfPresent(Bool.self, forKey: .supportsDirectPlay)
        supportsDirectStream = try values.decodeIfPresent(Bool.self, forKey: .supportsDirectStream)
        supportsTranscoding = try values.decodeIfPresent(Bool.self, forKey: .supportsTranscoding)
        isInfiniteStream = try values.decodeIfPresent(Bool.self, forKey: .isInfiniteStream)
        requiresOpening = try values.decodeIfPresent(Bool.self, forKey: .requiresOpening)
        openToken = try values.decodeIfPresent(String.self, forKey: .openToken)
        requiresClosing = try values.decodeIfPresent(Bool.self, forKey: .requiresClosing)
        liveStreamID = try values.decodeIfPresent(String.self, forKey: .liveStreamID)
        defaultAudioStreamIndex = try values.decodeIfPresent(Int.self, forKey: .defaultAudioStreamIndex)
        defaultSubtitleStreamIndex = try values.decodeIfPresent(Int.self, forKey: .defaultSubtitleStreamIndex)
        mediaStreams = try values.decodeIfPresent([JellyfinMediaStream].self, forKey: .mediaStreams) ?? []
        requiredHTTPHeaders = try values.decodeIfPresent([String: String].self, forKey: .requiredHTTPHeaders) ?? [:]
        transcodingURL = try values.decodeIfPresent(String.self, forKey: .transcodingURL)
        transcodingContainer = try values.decodeIfPresent(String.self, forKey: .transcodingContainer)
        transcodingSubProtocol = try values.decodeIfPresent(String.self, forKey: .transcodingSubProtocol)
    }
}

nonisolated extension JellyfinMediaSourceInfo {
    var videoStreams: [JellyfinMediaStream] { mediaStreams.filter { $0.type == .video } }
    var audioStreams: [JellyfinMediaStream] { mediaStreams.filter { $0.type == .audio } }
    var subtitleStreams: [JellyfinMediaStream] { mediaStreams.filter { $0.type == .subtitle } }
    var videoWidth: Int? { videoStreams.compactMap(\.width).max() }
    var videoHeight: Int? { videoStreams.compactMap(\.height).max() }

    /// Gelato entries are virtual Jellyfin media sources. Their paths must
    /// never be treated as local files or forwarded to diagnostics.
    var isGelatoVirtual: Bool {
        let candidates = [id, name, path, `protocol`].compactMap { $0?.lowercased() }
        return candidates.contains { value in
            value.hasPrefix("gelato:") || value.contains("gelato://") || value == "gelato"
        }
    }

    var liveStreamLifecycle: JellyfinLiveStreamLifecycle {
        JellyfinLiveStreamLifecycle(
            requiresOpening: requiresOpening ?? false,
            openToken: openToken,
            liveStreamID: liveStreamID,
            requiresClosing: requiresClosing ?? false
        )
    }
}

nonisolated struct JellyfinLiveStreamLifecycle: Equatable, Sendable {
    let requiresOpening: Bool
    let openToken: String?
    let liveStreamID: String?
    let requiresClosing: Bool
}
