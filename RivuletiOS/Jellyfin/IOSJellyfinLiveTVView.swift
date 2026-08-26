// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import SwiftUI

struct IOSJellyfinLiveTVView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var channels: [UnifiedChannel] = []
    @State private var epg: [String: [UnifiedProgram]] = [:]
    @State private var query = ""
    @State private var error: String?
    @State private var playback: IOSJellyfinLivePlaybackContext?
    @State private var tuningChannelID: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedChannels, id: \.0) { group, values in
                    Section(group) {
                        ForEach(values) { channel in
                            Button { Task { await tune(channel) } } label: {
                                HStack(spacing: 14) {
                                    AsyncImage(url: channel.logoURL) { phase in
                                        if case .success(let image) = phase { image.resizable().scaledToFit() }
                                        else { Image(systemName: "play.tv").font(.title2).foregroundStyle(.secondary) }
                                    }
                                    .frame(width: 58, height: 42)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            if let number = channel.channelNumber { Text(String(number)).foregroundStyle(.secondary) }
                                            Text(channel.name).font(.headline).lineLimit(1)
                                        }
                                        if let current = currentProgram(channel) {
                                            Text(current.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                            if let progress = current.currentProgress { ProgressView(value: progress).tint(.cyan) }
                                        }
                                    }
                                    Spacer()
                                    if tuningChannelID == channel.id { ProgressView() }
                                    else { Image(systemName: "play.fill").foregroundStyle(.cyan) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(tuningChannelID != nil)
                        }
                    }
                }
            }
            .overlay {
                if channels.isEmpty, error == nil { ProgressView() }
                if let error { ContentUnavailableView("Live TV unavailable", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text(error)) }
            }
            .navigationTitle("Live TV")
            .searchable(text: $query, prompt: "Channels or programmes")
            .refreshable { await load(force: true) }
            .task { await load() }
            .fullScreenCover(item: $playback) { IOSJellyfinLivePlayerView(context: $0) }
        }
    }

    private var filteredChannels: [UnifiedChannel] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return channels }
        return channels.filter { channel in
            channel.name.lowercased().contains(term)
                || currentProgram(channel)?.title.lowercased().contains(term) == true
        }
    }

    private var groupedChannels: [(String, [UnifiedChannel])] {
        Dictionary(grouping: filteredChannels) { $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Channels" }
            .map { key, value in (key, value.sorted { ($0.channelNumber ?? Int.max, $0.name) < ($1.channelNumber ?? Int.max, $1.name) }) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private func currentProgram(_ channel: UnifiedChannel) -> UnifiedProgram? {
        epg[channel.id]?.first(where: \.isCurrentlyAiring)
    }

    private func load(force: Bool = false) async {
        guard let provider = jellyfin.liveTVProvider else { return }
        do {
            let values = try await (force ? provider.refreshChannels() : provider.fetchChannels())
            channels = values
            epg = try await provider.fetchEPG(
                for: values,
                startDate: Date().addingTimeInterval(-30 * 60),
                endDate: Date().addingTimeInterval(8 * 60 * 60)
            )
            error = nil
        } catch { self.error = IOSJellyfinSession.message(for: error) }
    }

    private func tune(_ channel: UnifiedChannel) async {
        guard let provider = jellyfin.liveTVProvider else { return }
        tuningChannelID = channel.id
        defer { tuningChannelID = nil }
        guard let stream = await provider.resolveStream(for: channel) else {
            error = "Jellyfin did not return a playable stream for \(channel.name)."
            return
        }
        playback = IOSJellyfinLivePlaybackContext(
            channel: channel,
            program: currentProgram(channel),
            stream: stream,
            provider: provider
        )
    }
}

private struct IOSJellyfinLivePlaybackContext: Identifiable {
    let id = UUID()
    let channel: UnifiedChannel
    let program: UnifiedProgram?
    let stream: ResolvedLiveTVStream
    let provider: JellyfinLiveTVProvider
}

private struct IOSJellyfinLivePlayerView: View {
    let context: IOSJellyfinLivePlaybackContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AetherPlayer()
    @State private var controlsVisible = true
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AetherPlayerSurface(player: player).ignoresSafeArea()
            IOSPlayerTapSurface(onSingleTap: toggleControls, onDoubleTapLeft: {}, onDoubleTapRight: {}).ignoresSafeArea()
            if controlsVisible { controls.transition(.opacity) }
            if shouldShowActivity {
                ProgressView(context.channel.name).tint(.white).foregroundStyle(.white)
                    .padding(16).background(.ultraThinMaterial, in: Capsule())
            }
            if case .failed(let message) = player.state {
                VStack(spacing: 12) {
                    Text("Live TV stopped").font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
            }
        }
        .foregroundStyle(.white).statusBarHidden()
        .task { await load() }
        .onAppear { restartAutoHide() }
        .onDisappear {
            autoHideTask?.cancel(); player.stop()
            Task { await context.provider.endStream(context.stream) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                Spacer()
            }
            .padding()
            Spacer()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.channel.name).font(.headline)
                    if let program = context.program { Text(program.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Button { isPlaying ? player.pause() : player.play(); restartAutoHide() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 48, height: 48)
                }
                .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
            }
            .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).padding()
        }
        .background(LinearGradient(colors: [.black.opacity(0.58), .clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false))
    }

    private var shouldShowActivity: Bool {
        if case .idle = player.state { return true }
        if case .loading = player.state { return true }
        return player.isBuffering
    }
    private var isPlaying: Bool { if case .playing = player.state { return true }; return false }

    private func load() async {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            try await player.loadLive(url: context.stream.url, headers: context.stream.headers)
        } catch is CancellationError { }
        catch { }
    }

    private func toggleControls() { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }; restartAutoHide() }
    private func restartAutoHide() {
        autoHideTask?.cancel()
        guard controlsVisible else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
