// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import MediaPlayer
import SwiftUI

struct IOSJellyfinPlaybackContext: Identifiable {
    let id = UUID()
    let item: MediaItem
    let stream: StreamInfo
    let provider: JellyfinProvider
    let followingEpisodes: [MediaItem]
    let chapters: [MediaChapter]

    init(
        item: MediaItem,
        stream: StreamInfo,
        provider: JellyfinProvider,
        followingEpisodes: [MediaItem] = [],
        chapters: [MediaChapter] = []
    ) {
        self.item = item
        self.stream = stream
        self.provider = provider
        self.followingEpisodes = followingEpisodes
        self.chapters = chapters
    }
}

struct IOSJellyfinPlayerView: View {
    let context: IOSJellyfinPlaybackContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AetherPlayer()
    @StateObject private var watchTogether: JellyfinSyncPlaySessionModel
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
    @State private var chapters: [MediaChapter]
    @State private var preparedNextEpisode: PreparedEpisode?
    @State private var nextPreparationTask: Task<Void, Never>?
    @State private var hideUpNextPrompt = false
    @State private var watchGroupName = ""
    @State private var lastBufferingState = false
    @State private var nowPlayingArtwork: MPMediaItemArtwork?
    @State private var nowPlayingArtworkRef: MediaItemRef?
    @AppStorage("ios.autoplayNextEpisode") private var autoplayNextEpisode = true
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30
    @AppStorage("ios.showSkipIntro") private var showSkipIntro = true
    @AppStorage("ios.showSkipCredits") private var showSkipCredits = true

    init(context: IOSJellyfinPlaybackContext) {
        self.context = context
        _watchTogether = StateObject(wrappedValue: JellyfinSyncPlaySessionModel(provider: context.provider))
        _currentItem = State(initialValue: context.item)
        _currentStream = State(initialValue: context.stream)
        _episodeQueue = State(initialValue: context.followingEpisodes)
        _chapters = State(initialValue: context.chapters)
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
            if let chapter = activeSkippableChapter {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(chapter.isCredits ? "Skip Credits" : "Skip Intro", systemImage: "forward.end.fill") {
                            requestSeek(to: chapter.end ?? chapter.start + 90)
                        }
                        .buttonStyle(.plain)
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.trailing, 20).padding(.bottom, controlsVisible ? 122 : 24)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if shouldOfferUpNext, let next = preparedNextEpisode?.item ?? episodeQueue.first {
                upNextPrompt(next)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
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
        .task {
            configureWatchTogether()
            watchTogether.connect()
            await load()
        }
        .onAppear { restartAutoHide() }
        .onChange(of: player.sourceTime) { _, value in reportProgressIfNeeded(value) }
        .onChange(of: player.state) { _, state in
            updateSystemNowPlaying()
            guard state == .ended else { return }
            if watchTogether.isActive {
                Task { _ = await watchTogether.requestNextItem() }
            } else if autoplayNextEpisode, !episodeQueue.isEmpty {
                Task { await playNextEpisode() }
            }
        }
        .onChange(of: player.isBuffering) { _, buffering in
            guard buffering != lastBufferingState, watchTogether.isActive else { return }
            lastBufferingState = buffering
            Task {
                if buffering {
                    await watchTogether.buffering(position: player.sourceTime, isPlaying: isPlaying)
                } else {
                    await watchTogether.ready(position: player.sourceTime, isPlaying: isPlaying)
                }
            }
        }
        .onPreferenceChange(IOSPlayerRailTopPreferenceKey.self) { osdTop = $0 }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
        .sheet(item: $panel) {
            playerPanel($0)
                .presentationDetents($0 == .watchTogether || $0 == .upNext ? [.medium, .large] : [.medium])
                .presentationDragIndicator(.visible)
        }
        .onDisappear {
            autoHideTask?.cancel()
            nextPreparationTask?.cancel()
            let position = player.sourceTime
            player.stop()
            let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
            Task { await reporter.stopped(at: position) }
            Task { await watchTogether.disconnect(leavingGroup: true) }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var chrome: some View {
        IOSAdaptivePlayerChrome(
            eyebrow: currentItem.episodeHierarchyTitle,
            title: currentItem.title,
            currentTime: player.sourceTime,
            duration: max(currentStream.source.duration, player.duration),
            isSeekable: true,
            leadingAction: IOSPlayerTransportAction(
                title: "Back \(skipBackwardSeconds) seconds",
                systemImage: IOSPlayerSkipSymbol.backward(skipBackwardSeconds)
            ) { seek(by: -TimeInterval(skipBackwardSeconds)) },
            primaryAction: IOSPlayerTransportAction(
                title: isPlaying ? "Pause" : "Play",
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                prominent: true,
                disabled: shouldShowActivity
            ) { togglePlayback() },
            trailingAction: IOSPlayerTransportAction(
                title: "Forward \(skipForwardSeconds) seconds",
                systemImage: IOSPlayerSkipSymbol.forward(skipForwardSeconds)
            ) { seek(by: TimeInterval(skipForwardSeconds)) },
            onClose: { dismiss() },
            onSeek: { value in requestSeek(to: value) }
        ) {
            IOSPlayerControlButton(
                title: "Subtitles",
                systemImage: subtitleIcon,
                compact: true,
                dense: true,
                grouped: true
            ) { show(.subtitles) }
            IOSPlayerControlButton(
                title: "Audio",
                systemImage: "waveform",
                compact: true,
                dense: true,
                grouped: true
            ) { show(.audio) }
            IOSPlayerControlButton(
                title: "Playback",
                systemImage: "slider.horizontal.3",
                compact: true,
                dense: true,
                grouped: true
            ) { show(.playback) }
            if !episodeQueue.isEmpty {
                IOSPlayerControlButton(
                    title: "Up Next",
                    systemImage: "list.and.film",
                    compact: true,
                    dense: true,
                    grouped: true
                ) { show(.upNext) }
            }
            IOSPlayerControlButton(
                title: "Watch Together",
                systemImage: watchTogether.isActive ? "person.2.wave.2.fill" : "person.2.wave.2",
                compact: true,
                dense: true,
                grouped: true
            ) { show(.watchTogether) }
            IOSPlayerControlButton(
                title: "Info",
                systemImage: "info.circle",
                compact: true,
                dense: true,
                grouped: true
            ) { show(.info) }
        }
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
                    if let show = currentItem.seriesTitle { LabeledContent("TV Show", value: show) }
                    LabeledContent("Title", value: currentItem.title)
                    if let episode = currentItem.episodeCoordinate { LabeledContent("Episode", value: episode) }
                    if let season = currentItem.seasonDisplayTitle { LabeledContent("Season", value: season) }
                    if let resolution = currentStream.source.videoResolution { LabeledContent("Quality", value: resolution.uppercased()) }
                    if let container = currentStream.source.container { LabeledContent("Container", value: container.uppercased()) }
                    LabeledContent("Player", value: AetherPlayer.engineName)
                case .playback:
                    Section("Speed") {
                        Picker("Playback speed", selection: Binding(
                            get: { player.playbackRate },
                            set: { player.setRate($0) }
                        )) {
                            Text("0.5×").tag(Float(0.5))
                            Text("0.75×").tag(Float(0.75))
                            Text("Normal").tag(Float(1))
                            Text("1.25×").tag(Float(1.25))
                            Text("1.5×").tag(Float(1.5))
                            Text("2×").tag(Float(2))
                        }
                    }
                case .upNext:
                    if episodeQueue.isEmpty {
                        ContentUnavailableView("End of series", systemImage: "checkmark.circle")
                    } else {
                        ForEach(episodeQueue) { episode in
                            Button {
                                Task { await playEpisodeFromQueue(episode) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(episode.title)
                                    Text(episode.episodeHierarchyTitle ?? "Next episode")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .watchTogether:
                    watchTogetherPanel
                }
            }
            .navigationTitle(panel.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.panel = nil } } }
        }
    }

    @ViewBuilder private var watchTogetherPanel: some View {
        if let group = watchTogether.activeGroup {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.headline)
                        Text(group.state == .playing ? "Watching now" : group.state.rawValue)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(max(1, group.participants.count))")
                        .font(.headline.monospacedDigit())
                }
                ForEach(group.participants, id: \.self) { participant in
                    Label(participant, systemImage: "person.crop.circle.fill")
                }
            } header: {
                Text("Connected")
            }
            Section {
                Button("Leave Watch Together", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await watchTogether.leave() }
                }
            }
        } else {
            Section("Start a group") {
                TextField("Group name", text: $watchGroupName)
                Button("Start Watch Together", systemImage: "plus") {
                    let defaultName = "\(context.provider.session.user.name)’s Watch Party"
                    let ids = ([currentItem] + episodeQueue).map(\.ref.itemID)
                    Task {
                        await watchTogether.create(
                            named: watchGroupName.isEmpty ? defaultName : watchGroupName,
                            itemIDs: ids,
                            currentIndex: 0,
                            position: player.sourceTime
                        )
                    }
                }
                .disabled(watchTogether.isBusy)
            }

            Section("Available groups") {
                if watchTogether.groups.isEmpty, watchTogether.isConnected {
                    ContentUnavailableView("No groups yet", systemImage: "person.2.slash")
                } else if !watchTogether.isConnected {
                    HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
                } else {
                    ForEach(watchTogether.groups) { group in
                        Button {
                            Task { await watchTogether.join(group) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(group.name)
                                    Text("\(group.participants.count) watching")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await watchTogether.refreshGroups() }
                }
                .disabled(watchTogether.isBusy)
            }
        }

        if let message = watchTogether.message {
            Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }

    private func upNextPrompt(_ next: MediaItem) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "forward.end.fill")
                            .font(.title3).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(autoplayNextEpisode ? "Up next in \(upNextCountdown)s" : "Up Next")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(next.title).font(.headline).lineLimit(1)
                            if let episode = next.episodeHierarchyTitle {
                                Text(episode).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button { withAnimation(.snappy) { hideUpNextPrompt = true } } label: {
                            Image(systemName: "xmark").frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Button("Play Now", systemImage: "play.fill") { Task { await playNextEpisode() } }
                            .buttonStyle(.borderedProminent)
                        Button("Episodes", systemImage: "list.and.film") { show(.upNext) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .frame(width: 340)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.trailing, 18)
                .padding(.bottom, controlsVisible ? 122 : 22)
            }
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
    private var activeSkippableChapter: MediaChapter? {
        chapters.first { chapter in
            guard let end = chapter.end, player.sourceTime >= chapter.start, player.sourceTime < end else { return false }
            return (showSkipIntro && chapter.isIntro) || (showSkipCredits && chapter.isCredits)
        }
    }

    private var shouldOfferUpNext: Bool {
        guard !hideUpNextPrompt, !episodeQueue.isEmpty, player.duration > 0 else { return false }
        return player.duration - player.sourceTime <= 30 && player.duration - player.sourceTime > 0
    }

    private var upNextCountdown: Int {
        max(1, Int(ceil(max(0, player.duration - player.sourceTime))))
    }

    private func load() async {
        guard let url = currentStream.source.streamURL else { return }
        do {
            try IOSMediaAudioSession.activateForVideo()
            let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
            await reporter.start()
            try await player.load(
                url: url,
                headers: currentStream.requestHeaders,
                startTime: currentItem.userState.viewOffset > 0 ? currentItem.userState.viewOffset : nil
            )
            updateSystemNowPlaying()
            updateSystemNowPlayingArtwork(for: currentItem)
            prepareNextEpisode()
        } catch is CancellationError { }
        catch { }
    }

    private func togglePlayback() {
        let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
        if isPlaying {
            player.pause()
            Task {
                if watchTogether.isActive { await watchTogether.requestPause() }
                await reporter.paused(at: player.sourceTime)
            }
        } else {
            player.play()
            Task {
                if watchTogether.isActive { await watchTogether.requestUnpause() }
                await reporter.progress(position: player.sourceTime)
            }
        }
        updateSystemNowPlaying()
        restartAutoHide()
    }

    private func seek(by delta: TimeInterval) {
        let duration = max(currentStream.source.duration, player.duration)
        requestSeek(to: min(max(player.sourceTime + delta, 0), max(duration, 0)))
        restartAutoHide()
    }

    private func requestSeek(to position: TimeInterval) {
        Task {
            await player.seek(to: position)
            if watchTogether.isActive { await watchTogether.requestSeek(to: position) }
        }
        restartAutoHide()
    }

    private func reportProgressIfNeeded(_ value: TimeInterval) {
        let second = Int(value)
        guard second > 0, second % 10 == 0, second != lastReportedSecond else { return }
        lastReportedSecond = second
        let reporter = context.provider.progressReporter(for: currentItem.ref, streamInfo: currentStream)
        Task { await reporter.progress(position: value) }
        updateSystemNowPlaying()
    }

    private func playNextEpisode() async {
        guard !isAdvancing, let next = episodeQueue.first else { return }
        await playEpisodeFromQueue(next)
    }

    private func playEpisodeFromQueue(_ next: MediaItem) async {
        guard !isAdvancing, let nextIndex = episodeQueue.firstIndex(where: { $0.ref == next.ref }) else { return }
        if watchTogether.isActive {
            let requested: Bool
            if nextIndex == 0 {
                requested = await watchTogether.requestNextItem()
            } else {
                requested = await watchTogether.replaceQueue(
                    itemIDs: Array(episodeQueue.dropFirst(nextIndex)).map(\.ref.itemID)
                )
            }
            if requested { panel = nil; return }
        }
        isAdvancing = true
        defer { isAdvancing = false }
        let finishedReporter = context.provider.progressReporter(
            for: currentItem.ref,
            streamInfo: currentStream
        )
        await finishedReporter.stopped(at: max(player.sourceTime, currentStream.source.duration))
        do {
            let prepared = preparedNextEpisode?.item.ref == next.ref ? preparedNextEpisode : nil
            let stream: StreamInfo
            if let prepared {
                stream = prepared.stream
            } else {
                stream = try await context.provider.resolveStream(for: next.ref, sourceID: nil)
            }
            player.stop()
            episodeQueue.removeFirst(nextIndex + 1)
            nowPlayingArtwork = nil
            nowPlayingArtworkRef = nil
            currentItem = next
            currentStream = stream
            if let prepared {
                chapters = prepared.chapters
            } else if let detail = try? await context.provider.fullDetail(for: next.ref) {
                chapters = detail.chapters
            } else {
                chapters = []
            }
            preparedNextEpisode = nil
            hideUpNextPrompt = false
            lastReportedSecond = -1
            panel = nil
            await load()
        } catch {
            player.stop()
        }
    }

    private func prepareNextEpisode() {
        nextPreparationTask?.cancel()
        preparedNextEpisode = nil
        guard let next = episodeQueue.first else { return }
        nextPreparationTask = Task {
            do {
                async let stream = context.provider.resolveStream(for: next.ref, sourceID: nil)
                async let detail = context.provider.fullDetail(for: next.ref)
                let (loadedStream, loadedDetail) = try await (stream, detail)
                let prepared = PreparedEpisode(item: next, stream: loadedStream, chapters: loadedDetail.chapters)
                guard !Task.isCancelled, episodeQueue.first?.ref == next.ref else { return }
                preparedNextEpisode = prepared
            } catch is CancellationError { }
            catch { }
        }
    }

    /// Mirrors Apple's TV episode hierarchy in Control Center, the Lock Screen,
    /// AirPlay destinations and macOS Now Playing: episode title as the primary
    /// title, show as artist and season as album.
    private func updateSystemNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentItem.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.sourceTime),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(player.playbackRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        let duration = max(currentStream.source.duration, player.duration)
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let show = currentItem.seriesTitle { info[MPMediaItemPropertyArtist] = show }
        if let season = currentItem.seasonDisplayTitle { info[MPMediaItemPropertyAlbumTitle] = season }
        if let episode = currentItem.episodeNumber { info[MPMediaItemPropertyAlbumTrackNumber] = episode }
        if nowPlayingArtworkRef == currentItem.ref, let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateSystemNowPlayingArtwork(for item: MediaItem) {
        guard let url = item.artwork.backdrop ?? item.artwork.thumbnail ?? item.artwork.poster else { return }
        let expectedRef = item.ref
        Task {
            guard let image = await IOSArtworkCache.shared.image(for: url),
                  currentItem.ref == expectedRef else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingArtworkRef = expectedRef
            nowPlayingArtwork = artwork
            updateSystemNowPlaying()
        }
    }

    private func configureWatchTogether() {
        watchTogether.onEvent = { event in
            switch event {
            case .command(let command):
                applySyncPlayCommand(command)
            case .queueChanged(let queue):
                applySyncPlayQueue(queue)
            default:
                break
            }
        }
    }

    private func applySyncPlayCommand(_ command: JellyfinSyncPlayCommand) {
        Task {
            if let when = command.executeAt {
                let delay = max(0, when.timeIntervalSinceNow)
                if delay > 0 { try? await Task.sleep(for: .seconds(min(delay, 5))) }
            }
            switch command.kind {
            case .pause:
                player.pause()
            case .unpause:
                if let position = command.position, abs(player.sourceTime - position) > 1.25 {
                    await player.seek(to: position)
                }
                player.play()
            case .seek:
                if let position = command.position { await player.seek(to: position) }
            case .stop:
                player.stop()
                dismiss()
            }
        }
    }

    private func applySyncPlayQueue(_ queue: JellyfinSyncPlayQueueSnapshot) {
        guard let active = queue.current else { return }
        Task {
            if active.itemID == currentItem.ref.itemID {
                if abs(player.sourceTime - queue.startPosition) > 1.25 {
                    await player.seek(to: queue.startPosition)
                }
                queue.isPlaying ? player.play() : player.pause()
                await watchTogether.ready(position: player.sourceTime, isPlaying: queue.isPlaying)
                return
            }
            await loadSyncPlayItem(
                active.itemID,
                position: queue.startPosition,
                shouldPlay: queue.isPlaying,
                queue: queue
            )
        }
    }

    private func loadSyncPlayItem(
        _ itemID: String,
        position: TimeInterval,
        shouldPlay: Bool,
        queue: JellyfinSyncPlayQueueSnapshot
    ) async {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            let ref = MediaItemRef(providerID: context.provider.id, itemID: itemID)
            async let detail = context.provider.fullDetail(for: ref)
            async let stream = context.provider.resolveStream(for: ref, sourceID: nil)
            let loadedDetail = try await detail
            let loadedStream = try await stream
            player.stop()
            nowPlayingArtwork = nil
            nowPlayingArtworkRef = nil
            currentItem = loadedDetail.item
            currentStream = loadedStream
            chapters = loadedDetail.chapters
            episodeQueue = []
            preparedNextEpisode = nil
            lastReportedSecond = -1
            guard let url = loadedStream.source.streamURL else { return }
            let reporter = context.provider.progressReporter(for: ref, streamInfo: loadedStream)
            await reporter.start()
            try await player.load(url: url, headers: loadedStream.requestHeaders, startTime: position)
            if !shouldPlay { player.pause() }
            await watchTogether.ready(position: player.sourceTime, isPlaying: shouldPlay)
            rebuildFollowingEpisodes(from: queue, currentItemID: itemID)
        } catch {
            await watchTogether.buffering(position: position, isPlaying: shouldPlay)
        }
    }

    private func rebuildFollowingEpisodes(
        from queue: JellyfinSyncPlayQueueSnapshot,
        currentItemID: String
    ) {
        let nextIDs = queue.items
            .dropFirst(queue.playingIndex + 1)
            .prefix(12)
            .map(\.itemID)
        guard !nextIDs.isEmpty else { return }

        Task {
            var loaded: [MediaItem] = []
            loaded.reserveCapacity(nextIDs.count)
            for id in nextIDs {
                guard !Task.isCancelled else { return }
                let ref = MediaItemRef(providerID: context.provider.id, itemID: id)
                if let detail = try? await context.provider.fullDetail(for: ref) {
                    loaded.append(detail.item)
                }
            }
            guard currentItem.ref.itemID == currentItemID else { return }
            episodeQueue = loaded
            prepareNextEpisode()
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
        case subtitles, audio, playback, info, upNext, watchTogether
        var id: String { rawValue }
        var title: String {
            switch self {
            case .upNext: "Up Next"
            case .watchTogether: "Watch Together"
            default: rawValue.capitalized
            }
        }
    }

    private struct PreparedEpisode {
        let item: MediaItem
        let stream: StreamInfo
        let chapters: [MediaChapter]
    }
}

private extension MediaChapter {
    var normalizedTitle: String { (title ?? "").lowercased() }
    var isIntro: Bool { normalizedTitle.contains("intro") || normalizedTitle.contains("opening") }
    var isCredits: Bool {
        normalizedTitle.contains("credit") || normalizedTitle.contains("ending") || normalizedTitle.contains("outro")
    }
}
