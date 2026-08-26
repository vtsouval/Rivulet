// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import SwiftUI

struct IOSJellyfinLiveTVView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case channels = "Channels"
        case sports = "Sports"
        case favorites = "Favorites"
        var id: String { rawValue }
    }

    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var channels: [UnifiedChannel] = []
    @State private var epg: [String: [UnifiedProgram]] = [:]
    @State private var query = ""
    @State private var error: String?
    @State private var playback: IOSJellyfinLivePlaybackContext?
    @State private var tuningChannelID: String?
    @State private var mode: Mode = .channels
    @State private var country: IOSLiveTVCountry = .all
    @State private var category: IOSLiveTVCategory = .all
    @State private var favorites = Set<String>()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    filters
                    ForEach(groupedChannels, id: \.0) { group, values in
                        Section {
                        ForEach(values) { channel in
                            HStack(spacing: 10) {
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
                                Button { toggleFavorite(channel) } label: {
                                    Image(systemName: favorites.contains(channel.id) ? "heart.fill" : "heart")
                                        .foregroundStyle(favorites.contains(channel.id) ? .red : .secondary)
                                        .frame(width: 40, height: 40)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09)) }
                        }
                        } header: {
                            Text(group).font(.title3.bold()).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal).padding(.bottom, 30)
            }
            .overlay {
                if channels.isEmpty, error == nil { ProgressView() }
                if let error { ContentUnavailableView("Live TV unavailable", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text(error)) }
            }
            .navigationTitle("Live TV")
            .toolbar { IOSJellyfinAccountToolbar() }
            .searchable(text: $query, prompt: "Channels or programmes")
            .refreshable { await load(force: true) }
            .task { restorePreferences(); await load() }
            .onChange(of: mode) { _, _ in category = .all }
            .fullScreenCover(item: $playback) { IOSJellyfinLivePlayerView(context: $0) }
        }
    }

    private var filteredChannels: [UnifiedChannel] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return channels.filter { channel in
            let program = currentProgram(channel)
            let classification = IOSJellyfinLiveTVClassifier.classify(channel: channel, program: program)
            let matchesTerm = term.isEmpty || channel.name.lowercased().contains(term)
                || program?.title.lowercased().contains(term) == true
            let matchesMode: Bool
            switch mode {
            case .channels: matchesMode = classification.category != .sports
            case .sports: matchesMode = classification.category == .sports
            case .favorites: matchesMode = favorites.contains(channel.id)
            }
            let matchesCountry = mode == .sports || country == .all || classification.country == country
            let matchesCategory = category == .all || classification.category == category
            return matchesTerm && matchesMode && matchesCountry && matchesCategory
        }
    }

    private var groupedChannels: [(String, [UnifiedChannel])] {
        Dictionary(grouping: filteredChannels) { channel in
            IOSJellyfinLiveTVClassifier.classify(channel: channel, program: currentProgram(channel)).category.rawValue
        }
            .map { key, value in (key, value.sorted { ($0.channelNumber ?? Int.max, $0.name) < ($1.channelNumber ?? Int.max, $1.name) }) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private var availableCountries: [IOSLiveTVCountry] {
        let present = Set(channels.compactMap { channel -> IOSLiveTVCountry? in
            let value = IOSJellyfinLiveTVClassifier.classify(channel: channel, program: currentProgram(channel)).country
            return value == .international ? nil : value
        })
        return [.all] + IOSLiveTVCountry.allCases.filter { $0 != .all && present.contains($0) }
    }

    private var availableCategories: [IOSLiveTVCategory] {
        let present = Set(channels.map {
            IOSJellyfinLiveTVClassifier.classify(channel: $0, program: currentProgram($0)).category
        })
        return [.all] + IOSLiveTVCategory.allCases.filter { $0 != .all && present.contains($0) }
    }

    private var filters: some View {
        VStack(spacing: 12) {
            Picker("Live TV", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode != .sports {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(availableCountries) { value in
                            liveChip(selected: country == value) {
                                country = value
                                UserDefaults.standard.set(value.rawValue, forKey: countryPreferenceKey)
                            } label: { Text("\(value.flag) \(value.rawValue)") }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(availableCategories) { value in
                        liveChip(selected: category == value) { category = value } label: {
                            Label(value.rawValue, systemImage: value.symbolName)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func liveChip<Label: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label().font(.subheadline.weight(.semibold)).padding(.horizontal, 13).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.black : Color.primary)
        .background(selected ? Color.white : Color.clear, in: Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
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

    private var favoritesKey: String { "ios.liveTV.favorites.\(jellyfin.userName ?? "default")" }
    private var countryPreferenceKey: String { "ios.liveTV.country.\(jellyfin.userName ?? "default")" }

    private func restorePreferences() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        if let raw = UserDefaults.standard.string(forKey: countryPreferenceKey),
           let saved = IOSLiveTVCountry(rawValue: raw) { country = saved }
    }

    private func toggleFavorite(_ channel: UnifiedChannel) {
        if !favorites.insert(channel.id).inserted { favorites.remove(channel.id) }
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: favoritesKey)
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
    @State private var showsInfo = false

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
        .sheet(isPresented: $showsInfo) {
            NavigationStack {
                Form {
                    Section("Now Playing") {
                        LabeledContent("Channel", value: context.channel.name)
                        if let program = context.program {
                            LabeledContent("Programme", value: program.title)
                            LabeledContent("Time", value: program.timeRangeFormatted)
                            if let description = program.description, !description.isEmpty {
                                Text(description).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Volume") { IOSSystemVolumeSlider().frame(height: 38) }
                    if player.currentAVPlayer != nil {
                        Section("Play on another screen") {
                            HStack {
                                Label("AirPlay", systemImage: "airplayvideo")
                                Spacer()
                                IOSAirPlayRouteButton().frame(width: 44, height: 34)
                            }
                        }
                    }
                }
                .navigationTitle("Live TV")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsInfo = false } } }
            }
            .presentationDetents([.medium])
        }
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
                Button { showsInfo = true; autoHideTask?.cancel() } label: {
                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                if player.currentAVPlayer != nil {
                    IOSAirPlayRouteButton().frame(width: 40, height: 40)
                }
                Button { isPlaying ? player.pause() : player.play(); restartAutoHide() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 48, height: 48)
                }
                .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
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
