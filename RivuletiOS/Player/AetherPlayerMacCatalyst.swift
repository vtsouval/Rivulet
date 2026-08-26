// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI
import UIKit

/// Mac Catalyst playback host. AetherEngine's packaged FFmpeg XCFrameworks do
/// not contain Catalyst slices, so Jellyfin negotiates Apple-compatible HLS
/// and this host uses the system AVPlayer stack. Keeping the same public
/// surface lets the iPhone/iPad and Mac applications share all player chrome.
@MainActor
final class AetherPlayer: ObservableObject {
    static let engineName = "AVPlayer"

    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case ended
        case failed(String)
    }

    struct Track: Identifiable, Hashable {
        let id: Int
        let name: String
        let codec: String
        let language: String?
        let channels: Int
        let isDefault: Bool
        let isForced: Bool
        let isHearingImpaired: Bool

        var detail: String {
            var parts: [String] = []
            if let language, !language.isEmpty {
                parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
            }
            if !codec.isEmpty { parts.append(codec.uppercased()) }
            if channels > 0 { parts.append(channels == 2 ? "Stereo" : "\(channels) ch") }
            if isHearingImpaired { parts.append("SDH") }
            if isForced { parts.append("Forced") }
            return parts.joined(separator: " · ")
        }
    }

    struct SubtitleCue: Identifiable {
        struct StyledRun: Hashable {
            let text: String
            let color: UIColor?
            let isBold: Bool
            let isItalic: Bool
            let isUnderlined: Bool
            let isStruckThrough: Bool
            let fontName: String?
            let fontSize: Int?
        }

        struct TextPlacement: Hashable {
            let alignment: Int?
            let position: CGPoint?
        }

        enum Body {
            case text(String)
            case styledText([StyledRun])
            case image(UIImage, CGRect)
        }

        let id: Int
        let startTime: Double
        let endTime: Double
        let body: Body
        let placement: TextPlacement?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isBuffering = false
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentAudioTrackId: Int?
    @Published private(set) var currentSubtitleTrackId: Int?
    @Published private(set) var subtitleCues: [SubtitleCue] = []
    @Published private(set) var nativeSubtitleCues: [SubtitleCue] = []
    @Published private(set) var sourceTime: Double = 0
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var playbackRate: Float = 1

    let avPlayer = AVPlayer()
    var currentAVPlayer: AVPlayer? { avPlayer }
    private var cancellables = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioOptions: [AVMediaSelectionOption] = []
    private var subtitleOptions: [AVMediaSelectionOption] = []

    init() {
        avPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .playing:
                    self.state = .playing
                    self.isBuffering = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = self.avPlayer.currentItem != nil
                case .paused:
                    if self.avPlayer.currentItem != nil, self.state != .ended,
                       !self.isBuffering, self.state != .loading {
                        self.state = .paused
                    }
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard time.isNumeric else { return }
            self?.sourceTime = max(0, time.seconds)
        }

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, note.object as? AVPlayerItem === self.avPlayer.currentItem else { return }
                self.state = .ended
                self.isBuffering = false
            }
            .store(in: &cancellables)
    }

    deinit {
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
    }

    func loadLive(url: URL, headers: [String: String]? = nil) async throws {
        try await load(url: url, headers: headers, startTime: nil)
    }

    func load(
        url: URL,
        headers: [String: String]? = nil,
        startTime: TimeInterval? = nil
    ) async throws {
        state = .loading
        isBuffering = true
        sourceTime = 0

        var options: [String: Any] = [:]
        if let headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw PlaybackFailure.notPlayable }

        let item = AVPlayerItem(asset: asset)
        observe(item)
        avPlayer.replaceCurrentItem(with: item)
        configureMediaSelection(for: item)

        if let startTime, startTime > 0 {
            await seek(to: startTime)
        }
        avPlayer.play()
    }

    func play() { avPlayer.play() }

    func pause() {
        avPlayer.pause()
        state = .paused
    }

    func setRate(_ rate: Float) {
        let sanitized = min(max(rate, 0.5), 2)
        playbackRate = sanitized
        avPlayer.defaultRate = sanitized
        if avPlayer.rate > 0 {
            avPlayer.rate = sanitized
        }
    }

    func seek(to time: TimeInterval) async {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        await avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var duration: TimeInterval {
        guard let duration = avPlayer.currentItem?.duration, duration.isNumeric else { return 0 }
        return max(0, duration.seconds)
    }

    func selectAudioTrack(id: Int) {
        guard let item = avPlayer.currentItem,
              let group = audioGroup,
              audioOptions.indices.contains(id) else { return }
        item.select(audioOptions[id], in: group)
        currentAudioTrackId = id
    }

    func selectSubtitleTrack(id: Int?) {
        guard let item = avPlayer.currentItem, let group = subtitleGroup else { return }
        if let id, subtitleOptions.indices.contains(id) {
            item.select(subtitleOptions[id], in: group)
            currentSubtitleTrackId = id
        } else {
            item.select(nil, in: group)
            currentSubtitleTrackId = nil
        }
    }

    func stop() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        audioGroup = nil
        subtitleGroup = nil
        audioOptions = []
        subtitleOptions = []
        audioTracks = []
        subtitleTracks = []
        currentAudioTrackId = nil
        currentSubtitleTrackId = nil
        subtitleCues = []
        nativeSubtitleCues = []
        videoSize = .zero
        sourceTime = 0
        playbackRate = 1
        avPlayer.defaultRate = 1
        isBuffering = false
        state = .idle
    }

    private func observe(_ item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, item === self.avPlayer.currentItem else { return }
                switch status {
                case .readyToPlay:
                    self.isBuffering = false
                    if self.avPlayer.rate > 0 { self.state = .playing }
                case .failed:
                    self.isBuffering = false
                    self.state = .failed(item?.error?.localizedDescription ?? "Playback failed")
                default:
                    break
                }
            }
            .store(in: &cancellables)

        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] size in
                guard let self, item === self.avPlayer.currentItem else { return }
                self.videoSize = size
            }
            .store(in: &cancellables)
    }

    private func configureMediaSelection(for item: AVPlayerItem) {
        let asset = item.asset
        audioGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
        subtitleGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        audioOptions = audioGroup?.options ?? []
        subtitleOptions = subtitleGroup?.options ?? []

        audioTracks = audioOptions.enumerated().map { index, option in
            track(option, id: index, defaultOption: audioGroup?.defaultOption)
        }
        subtitleTracks = subtitleOptions.enumerated().map { index, option in
            track(option, id: index, defaultOption: subtitleGroup?.defaultOption)
        }
        currentAudioTrackId = selectedIndex(in: audioGroup, options: audioOptions, item: item)
        currentSubtitleTrackId = selectedIndex(in: subtitleGroup, options: subtitleOptions, item: item)
        applyLanguagePreferences(to: item)
    }

    private func track(
        _ option: AVMediaSelectionOption,
        id: Int,
        defaultOption: AVMediaSelectionOption?
    ) -> Track {
        Track(
            id: id,
            name: option.displayName,
            codec: "",
            language: option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier,
            channels: 0,
            isDefault: option == defaultOption,
            isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
            isHearingImpaired: option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
        )
    }

    private func selectedIndex(
        in group: AVMediaSelectionGroup?,
        options: [AVMediaSelectionOption],
        item: AVPlayerItem
    ) -> Int? {
        guard let group,
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return options.firstIndex(of: selected)
    }

    private func applyLanguagePreferences(to item: AVPlayerItem) {
        let defaults = UserDefaults.standard
        let audioLanguage = defaults.string(forKey: "ios.preferredAudioLanguage") ?? "en"
        let subtitleLanguage = defaults.string(forKey: "ios.preferredSubtitleLanguage") ?? "en"

        if let group = audioGroup,
           let option = AVMediaSelectionGroup.mediaSelectionOptions(
               from: audioOptions,
               with: Locale(identifier: audioLanguage)
           ).first {
            item.select(option, in: group)
            currentAudioTrackId = audioOptions.firstIndex(of: option)
        }
        if let group = subtitleGroup {
            if subtitleLanguage == "off" {
                item.select(nil, in: group)
                currentSubtitleTrackId = nil
            } else if let option = AVMediaSelectionGroup.mediaSelectionOptions(
                from: subtitleOptions,
                with: Locale(identifier: subtitleLanguage)
            ).first {
                item.select(option, in: group)
                currentSubtitleTrackId = subtitleOptions.firstIndex(of: option)
            }
        }
    }

    private enum PlaybackFailure: LocalizedError {
        case notPlayable
        var errorDescription: String? { "This stream is not compatible with the Mac player." }
    }
}

struct AetherPlayerSurface: UIViewRepresentable {
    @ObservedObject var player: AetherPlayer

    final class HostingView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            playerLayer.videoGravity = .resizeAspect
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    func makeUIView(context: Context) -> HostingView {
        let view = HostingView()
        view.playerLayer.player = player.avPlayer
        return view
    }

    func updateUIView(_ uiView: HostingView, context: Context) {
        uiView.playerLayer.player = player.avPlayer
    }

    static func dismantleUIView(_ uiView: HostingView, coordinator: Void) {
        uiView.playerLayer.player = nil
    }
}
#endif
