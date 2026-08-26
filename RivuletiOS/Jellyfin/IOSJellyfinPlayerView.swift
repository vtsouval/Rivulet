// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import SwiftUI

struct IOSJellyfinPlaybackContext: Identifiable {
    let id = UUID()
    let item: MediaItem
    let stream: StreamInfo
    let provider: JellyfinProvider
    let followingEpisodes: [MediaItem]

    init(
        item: MediaItem,
        stream: StreamInfo,
        provider: JellyfinProvider,
        followingEpisodes: [MediaItem] = []
    ) {
        self.item = item
        self.stream = stream
        self.provider = provider
        self.followingEpisodes = followingEpisodes
    }
}

struct IOSJellyfinPlayerView: View {
    let context: IOSJellyfinPlaybackContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AetherPlayer()
    @State private var controlsVisible = true
    @State private var panel: Panel?
    @State private var autoHideTask: Task<Void, Never>?
    @State private var lastReportedSecond = -1
    @State private var captionStyle = CaptionAppearance.current()
    @State private var osdTop: CGFloat?
    @State private var currentItem: MediaItem
    @State private var currentStream: StreamInfo
    @State private var episodeQueue: [MediaItem]
    @State private var isAdvancing = false
    @AppStorage("ios.autoplayNextEpisode") private var autoplayNextEpisode = true
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30

    init(context: IOSJellyfinPlaybackContext) {
        self.context = context
        _currentItem = State(initialValue: context.item)
        _currentStream = State(initialValue: context.stream)
        _episodeQueue = State(initialValue: context.followingEpisodes)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AetherPlayerSurface(player: player).ignoresSafeArea()
            IOSAetherSubtitleOverlay(
                cues: visibleSubtitleCues,
                nativeCues: player.nativeSubtitleCues,
                style: captionStyle,
                landscapeOSDTop: controlsVisible ? osdTop : nil,
                videoSize: player.videoSize
            )
            .ignoresSafeArea()
            IOSPlayerTapSurface(
                onSingleTap: toggleControls,
                onDoubleTapLeft: { seek(by: -TimeInterval(skipBackwardSeconds)) },
                onDoubleTapRight: { seek(by: TimeInterval(skipForwardSeconds)) }
            )
            .ignoresSafeArea()

            if controlsVisible { chrome.transition(.opacity) }
            if shouldShowActivity {
                ProgressView(player.isBuffering ? "Buffering…" : currentItem.title)
                    .tint(.white).foregroundStyle(.white).padding(16)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if case .failed(let message) = player.state { errorCard(message) }
        }
        .coordinateSpace(name: IOSPlayerChromeCoordinateSpace.name)
        .foregroundStyle(.white)
        .statusBarHidden()
        .task { await load() }
        .onAppear { restartAutoHide() }
        .onChange(of: player.sourceTime) { _, value in reportProgressIfNeeded(value) }
        .onChange(of: player.state) { _, state in
            guard state == .ended, autoplayNextEpisode, !episodeQueue.isEmpty else { return }
            Task { await playNextEpisode() }
        }
        .onPreferenceChange(IOSPlayerRailTopPreferenceKey.self) { osdTop = $0 }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
        .sheet(item: $panel) { playerPanel($0).presentationDetents([.medium]).presentationDragIndicator(.visible) }
        .onDisappear {
            autoHideTask?.cancel()
            let position = player.sourceTime
            player.stop()
            let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
            Task { await reporter.stopped(at: position) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)
            Spacer()
            IOSPlayerGlassRail(
                eyebrow: currentItem.episodeString,
                title: currentItem.title,
                currentTime: player.sourceTime,
                duration: max(currentStream.source.duration, player.duration),
                isSeekable: true,
                centerControl: AnyView(
                    IOSPlayerControlButton(
                        title: isPlaying ? "Pause" : "Play",
                        systemImage: isPlaying ? "pause.fill" : "play.fill",
                        prominent: true,
                        compact: true,
                        disabled: shouldShowActivity
                    ) { togglePlayback() }
                ),
                compact: true,
                onSeek: { value in Task { await player.seek(to: value) } }
            ) {
                HStack(spacing: 4) {
                    IOSPlayerControlButton(title: "Subtitles", systemImage: subtitleIcon, compact: true, dense: true) { show(.subtitles) }
                    IOSPlayerControlButton(title: "Audio", systemImage: "waveform", compact: true, dense: true) { show(.audio) }
                    if !episodeQueue.isEmpty {
                        IOSPlayerControlButton(title: "Next", systemImage: "forward.end.fill", compact: true, dense: true) {
                            Task { await playNextEpisode() }
                        }
                    }
                    IOSPlayerControlButton(title: "Info", systemImage: "info.circle", compact: true, dense: true) { show(.info) }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: IOSPlayerRailTopPreferenceKey.self, value: proxy.frame(in: .named(IOSPlayerChromeCoordinateSpace.name)).minY)
                }
            }
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.62), .clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        )
    }

    @ViewBuilder private func playerPanel(_ panel: Panel) -> some View {
        NavigationStack {
            List {
                switch panel {
                case .subtitles:
                    Button { player.selectSubtitleTrack(id: nil); self.panel = nil } label: {
                        trackRow("Off", detail: nil, selected: player.currentSubtitleTrackId == nil)
                    }
                    ForEach(player.subtitleTracks) { track in
                        Button { player.selectSubtitleTrack(id: track.id); self.panel = nil } label: {
                            trackRow(track.name, detail: track.detail, selected: player.currentSubtitleTrackId == track.id)
                        }
                    }
                case .audio:
                    ForEach(player.audioTracks) { track in
                        Button { player.selectAudioTrack(id: track.id); self.panel = nil } label: {
                            trackRow(track.name, detail: track.detail, selected: player.currentAudioTrackId == track.id)
                        }
                    }
                case .info:
                    LabeledContent("Title", value: currentItem.title)
                    if let resolution = currentStream.source.videoResolution { LabeledContent("Quality", value: resolution.uppercased()) }
                    if let container = currentStream.source.container { LabeledContent("Container", value: container.uppercased()) }
                    LabeledContent("Player", value: AetherPlayer.engineName)
                }
            }
            .navigationTitle(panel.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.panel = nil } } }
        }
    }

    private func trackRow(_ title: String, detail: String?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) { Text(title); if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) } }
            Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.yellow)
            Text("Couldn’t play this video").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(20).frame(maxWidth: 360).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
    }

    private var visibleSubtitleCues: [AetherPlayer.SubtitleCue] {
        player.subtitleCues.filter { $0.startTime <= player.sourceTime && $0.endTime >= player.sourceTime }
    }
    private var shouldShowActivity: Bool {
        if case .idle = player.state { return true }
        if case .loading = player.state { return true }
        return player.isBuffering
    }
    private var isPlaying: Bool { if case .playing = player.state { return true }; return false }
    private var subtitleIcon: String { player.currentSubtitleTrackId == nil ? "captions.bubble" : "captions.bubble.fill" }

    private func load() async {
        guard let url = currentStream.source.streamURL else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
            await reporter.start()
            try await player.load(
                url: url,
                headers: currentStream.requestHeaders,
                startTime: currentItem.userState.viewOffset > 0 ? currentItem.userState.viewOffset : nil
            )
        } catch is CancellationError { }
        catch { }
    }

    private func togglePlayback() {
        let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
        if isPlaying {
            player.pause(); Task { await reporter.paused(at: player.sourceTime) }
        } else {
            player.play(); Task { await reporter.progress(position: player.sourceTime) }
        }
        restartAutoHide()
    }

    private func seek(by delta: TimeInterval) {
        let duration = max(currentStream.source.duration, player.duration)
        Task { await player.seek(to: min(max(player.sourceTime + delta, 0), max(duration, 0))) }
        restartAutoHide()
    }

    private func reportProgressIfNeeded(_ value: TimeInterval) {
        let second = Int(value)
        guard second > 0, second % 10 == 0, second != lastReportedSecond else { return }
        lastReportedSecond = second
        let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
        Task { await reporter.progress(position: value) }
    }

    private func playNextEpisode() async {
        guard !isAdvancing, let next = episodeQueue.first else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        let finishedReporter = context.provider.progressReporter(
            for: currentItem.ref,
            streamInfo: currentStream
        )
        await finishedReporter.stopped(at: max(player.sourceTime, currentStream.source.duration))
        do {
            let stream = try await context.provider.resolveStream(for: next.ref, sourceID: nil)
            player.stop()
            episodeQueue.removeFirst()
            currentItem = next
            currentStream = stream
            lastReportedSecond = -1
            await load()
        } catch {
            player.stop()
        }
    }

    private func show(_ panel: Panel) { autoHideTask?.cancel(); self.panel = panel }
    private func toggleControls() { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }; restartAutoHide() }
    private func restartAutoHide() {
        autoHideTask?.cancel()
        guard controlsVisible, panel == nil else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, panel == nil else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private enum Panel: String, Identifiable {
        case subtitles, audio, info
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
}
