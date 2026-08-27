// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import SwiftUI

struct IOSJellyfinLiveTVView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case channels = "Channels"
        case guide = "Guide"
        case sports = "Sports"
        case favorites = "Favorites"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .channels: "rectangle.grid.1x2"
            case .guide: "calendar.day.timeline.left"
            case .sports: "sportscourt"
            case .favorites: "heart"
            }
        }
    }

    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var channels: [UnifiedChannel] = []
    @State private var epg: [String: [UnifiedProgram]] = [:]
    @State private var snapshots: [String: IOSJellyfinLiveChannelSnapshot] = [:]
    @State private var query = ""
    @State private var error: String?
    @State private var guideWarning: String?
    @State private var isLoading = false
    @State private var playback: IOSJellyfinLivePlaybackContext?
    @State private var tuningChannelID: String?
    @State private var mode: Mode = .channels
    @State private var country: IOSLiveTVCountry = .all
    @State private var category: IOSLiveTVCategory = .all
    @State private var favorites = Set<String>()
    @State private var defaultCountry: IOSLiveTVCountry = .all
    @State private var sportsCountry: IOSLiveTVCountry = .greece
    @AppStorage("ios.liveTV.startInFavorites") private var startInFavorites = false
    @AppStorage("ios.liveTV.showProgress") private var showProgress = true
    @AppStorage("ios.liveTV.preloadGuide") private var preloadGuide = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                if let guideWarning {
                    Label(guideWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                liveContent
            }
            .overlay { statusOverlay }
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
                IOSJellyfinAccountToolbar()
            }
            .searchable(text: $query, prompt: "Channels or programmes")
            .refreshable { await load(force: true) }
            .task {
                restorePreferences()
                await load()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    rebuildSnapshots()
                }
            }
            .onChange(of: mode) { _, value in
                category = .all
                switch value {
                case .sports: country = sportsCountry
                case .channels, .guide, .favorites: country = defaultCountry
                }
            }
            .fullScreenCover(item: $playback) { IOSJellyfinLivePlayerView(context: $0) }
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        if mode == .guide {
            IOSJellyfinLiveGuideView(
                snapshots: filteredSnapshots,
                onTune: tuneFromGuide
            )
        } else {
            channelList
        }
    }

    private func tuneFromGuide(_ channel: UnifiedChannel, _ program: UnifiedProgram?) async {
        await tune(channel, program: program)
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedSnapshots, id: \.0) { group, values in
                    Section {
                        ForEach(values) { snapshot in channelRow(snapshot) }
                    } header: {
                        Text(group)
                            .font(.title3.bold())
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .overlay { emptyChannelsOverlay }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if channels.isEmpty, error == nil, isLoading {
            ProgressView("Loading every channel…")
                .padding(18)
                .background(.ultraThinMaterial, in: Capsule())
        } else if let error, channels.isEmpty {
            ContentUnavailableView {
                Label("Live TV unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(error)
            }
        }
    }

    @ViewBuilder
    private var emptyChannelsOverlay: some View {
        if !isLoading, filteredSnapshots.isEmpty, error == nil {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySymbol)
            } description: {
                Text("Try another country, category, or search.")
            }
        }
    }

    private var emptyTitle: String {
        mode == .favorites ? "No favorite channels" : "No matching channels"
    }

    private var emptySymbol: String {
        mode == .favorites ? "heart" : "tv.slash"
    }

    private func channelRow(_ snapshot: IOSJellyfinLiveChannelSnapshot) -> some View {
        let channel = snapshot.channel
        return HStack(spacing: 10) {
            Button { Task { await tune(channel, program: snapshot.currentProgram) } } label: {
                HStack(spacing: 14) {
                    AsyncImage(url: channel.logoURL) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFit() }
                        else { Image(systemName: "play.tv").font(.title2).foregroundStyle(.secondary) }
                    }
                    .frame(width: 62, height: 46)
                    .padding(4)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            if let number = channel.channelNumber {
                                Text(String(number)).foregroundStyle(.secondary)
                            }
                            Text(channel.name).font(.headline).lineLimit(1)
                            if channel.isHD {
                                Text("HD").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }
                        }
                        if let current = snapshot.currentProgram {
                            Text(current.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            if showProgress, let progress = current.currentProgress {
                                ProgressView(value: progress).tint(.cyan)
                            }
                        } else {
                            Text("Live now").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let next = snapshot.nextProgram {
                            Text("Next \(next.startTime.formatted(date: .omitted, time: .shortened)) · \(next.title)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
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
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorites.contains(channel.id) ? "Remove favorite" : "Add favorite")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09)) }
    }

    private var filteredSnapshots: [IOSJellyfinLiveChannelSnapshot] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshots.values.filter { snapshot in
            let channel = snapshot.channel
            let matchesTerm = term.isEmpty || channel.name.lowercased().contains(term)
                || snapshot.programs.contains { $0.title.lowercased().contains(term) }
            let matchesMode: Bool
            switch mode {
            case .channels, .guide: matchesMode = true
            case .sports: matchesMode = snapshot.classification.category == .sports
            case .favorites: matchesMode = favorites.contains(channel.id)
            }
            let matchesCountry = country == .all || snapshot.classification.country == country
            let matchesCategory = category == .all || snapshot.classification.category == category
            return matchesTerm && matchesMode && matchesCountry && matchesCategory
        }
        .sorted { ($0.channel.channelNumber ?? Int.max, $0.channel.name) < ($1.channel.channelNumber ?? Int.max, $1.channel.name) }
    }

    private var groupedSnapshots: [(String, [IOSJellyfinLiveChannelSnapshot])] {
        Dictionary(grouping: filteredSnapshots) { snapshot in
            snapshot.classification.category.rawValue
        }
            .map { key, value in (key, value) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private var availableCountries: [IOSLiveTVCountry] {
        let present = Set(snapshots.values.map(\.classification.country))
        return [.all] + IOSLiveTVCountry.allCases.filter { $0 != .all && present.contains($0) }
    }

    private var availableCategories: [IOSLiveTVCategory] {
        let present = Set(snapshots.values.map(\.classification.category))
        return [.all] + IOSLiveTVCategory.allCases.filter { $0 != .all && present.contains($0) }
    }

    private var filters: some View {
        VStack(spacing: 12) {
            Picker("Live TV", selection: $mode) {
                ForEach(Mode.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(availableCountries) { value in
                        liveChip(selected: country == value) {
                            country = value
                            if mode == .sports {
                                sportsCountry = value
                                UserDefaults.standard.set(value.rawValue, forKey: sportsCountryPreferenceKey)
                            } else {
                                defaultCountry = value
                                UserDefaults.standard.set(value.rawValue, forKey: countryPreferenceKey)
                            }
                        } label: { Text("\(value.flag) \(value.rawValue)") }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if mode != .sports {
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

            if !channels.isEmpty {
                Text(channelCountLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(filteredSnapshots.count) of \(channels.count) channels")
            }
        }
        .animation(.snappy(duration: 0.24), value: mode)
    }

    private var channelCountLabel: String {
        filteredSnapshots.count == channels.count
            ? "\(channels.count) channels"
            : "\(filteredSnapshots.count) of \(channels.count) channels"
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

    private func load(force: Bool = false) async {
        guard let provider = jellyfin.liveTVProvider else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let values = try await (force ? provider.refreshChannels() : provider.fetchChannels())
            channels = values
            rebuildSnapshots()
            error = nil
            do {
                epg = try await provider.fetchEPG(
                    for: values,
                    startDate: Date().addingTimeInterval(-2 * 60 * 60),
                    endDate: Date().addingTimeInterval((preloadGuide ? 12 : 4) * 60 * 60)
                )
                guideWarning = nil
                rebuildSnapshots()
            } catch {
                guideWarning = "The guide is refreshing; every channel remains available."
            }
        } catch {
            self.error = IOSJellyfinSession.message(for: error)
        }
    }

    private var favoritesKey: String { "ios.liveTV.favorites.\(jellyfin.userName ?? "default")" }
    private var countryPreferenceKey: String { "ios.liveTV.country.\(jellyfin.userName ?? "default")" }
    private var sportsCountryPreferenceKey: String { "ios.liveTV.sportsCountry.\(jellyfin.userName ?? "default")" }

    private func restorePreferences() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        if let raw = UserDefaults.standard.string(forKey: countryPreferenceKey),
           let saved = IOSLiveTVCountry(rawValue: raw) {
            defaultCountry = saved
            country = saved
        }
        if let raw = UserDefaults.standard.string(forKey: sportsCountryPreferenceKey),
           let saved = IOSLiveTVCountry(rawValue: raw) { sportsCountry = saved }
        if startInFavorites { mode = .favorites }
    }

    private func toggleFavorite(_ channel: UnifiedChannel) {
        if !favorites.insert(channel.id).inserted { favorites.remove(channel.id) }
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: favoritesKey)
    }

    private func rebuildSnapshots() {
        let now = Date()
        snapshots = Dictionary(uniqueKeysWithValues: channels.map { channel in
            let programs = (epg[channel.id] ?? [])
                .filter { $0.endTime > now.addingTimeInterval(-5 * 60) }
                .sorted { $0.startTime < $1.startTime }
            let current = programs.first { $0.startTime <= now && $0.endTime > now }
            return (
                channel.id,
                IOSJellyfinLiveChannelSnapshot(
                    channel: channel,
                    programs: programs,
                    currentProgram: current,
                    classification: IOSJellyfinLiveTVClassifier.classify(channel: channel, program: current)
                )
            )
        })
    }

    private func tune(_ channel: UnifiedChannel, program: UnifiedProgram? = nil) async {
        guard let provider = jellyfin.liveTVProvider else { return }
        tuningChannelID = channel.id
        defer { tuningChannelID = nil }
        guard let stream = await provider.resolveStream(for: channel) else {
            error = "Jellyfin did not return a playable stream for \(channel.name)."
            return
        }
        playback = IOSJellyfinLivePlaybackContext(
            channel: channel,
            program: program ?? snapshots[channel.id]?.currentProgram,
            stream: stream,
            provider: provider,
            lineup: filteredSnapshots
        )
    }
}

private struct IOSJellyfinLivePlaybackContext: Identifiable {
    let id = UUID()
    let channel: UnifiedChannel
    let program: UnifiedProgram?
    let stream: ResolvedLiveTVStream
    let provider: JellyfinLiveTVProvider
    let lineup: [IOSJellyfinLiveChannelSnapshot]
}

private struct IOSJellyfinLivePlayerView: View {
    let context: IOSJellyfinLivePlaybackContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AetherPlayer()
    @State private var activeChannel: UnifiedChannel
    @State private var activeProgram: UnifiedProgram?
    @State private var activeStream: ResolvedLiveTVStream
    @State private var controlsVisible = true
    @State private var autoHideTask: Task<Void, Never>?
    @State private var showsInfo = false
    @State private var showsGuide = false
    @State private var isSwitchingChannel = false

    init(context: IOSJellyfinLivePlaybackContext) {
        self.context = context
        _activeChannel = State(initialValue: context.channel)
        _activeProgram = State(initialValue: context.program)
        _activeStream = State(initialValue: context.stream)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AetherPlayerSurface(player: player).ignoresSafeArea()
            IOSPlayerTapSurface(onSingleTap: toggleControls, onDoubleTapLeft: {}, onDoubleTapRight: {}).ignoresSafeArea()
            if controlsVisible { controls.transition(.opacity) }
            if shouldShowActivity {
                ProgressView(activeChannel.name).tint(.white).foregroundStyle(.white)
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
                        LabeledContent("Channel", value: activeChannel.name)
                        if let program = activeProgram {
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
        .sheet(isPresented: $showsGuide) {
            IOSJellyfinMiniGuideSheet(
                snapshots: context.lineup,
                activeChannelID: activeChannel.id
            ) { snapshot in
                showsGuide = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(160))
                    await switchChannel(to: snapshot)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task { await load(activeStream) }
        .onAppear { restartAutoHide() }
        .onDisappear {
            autoHideTask?.cancel(); player.stop()
            let stream = activeStream
            Task { await context.provider.endStream(stream) }
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
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activeChannel.name).font(.headline)
                        if let program = activeProgram {
                            Text(program.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { isPlaying ? player.pause() : player.play(); restartAutoHide() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                }

                HStack(spacing: 14) {
                    Button { Task { await switchRelative(-1) } } label: {
                        Image(systemName: "backward.end.fill").frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                    .disabled(isSwitchingChannel || relativeSnapshot(-1) == nil)
                    Button { showsGuide = true; autoHideTask?.cancel() } label: {
                        Image(systemName: "list.bullet.rectangle").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                    Button { Task { await switchRelative(1) } } label: {
                        Image(systemName: "forward.end.fill").frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                    .disabled(isSwitchingChannel || relativeSnapshot(1) == nil)
                    Button { showsInfo = true; autoHideTask?.cancel() } label: {
                        Image(systemName: "info.circle").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
                    if player.currentAVPlayer != nil {
                        IOSAirPlayRouteButton().frame(width: 40, height: 40)
                    }
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
        }
        .background(LinearGradient(colors: [.black.opacity(0.58), .clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false))
    }

    private var shouldShowActivity: Bool {
        if isSwitchingChannel { return true }
        if case .idle = player.state { return true }
        if case .loading = player.state { return true }
        return player.isBuffering
    }
    private var isPlaying: Bool { if case .playing = player.state { return true }; return false }

    private func load(_ stream: ResolvedLiveTVStream) async {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            try await player.loadLive(url: stream.url, headers: stream.headers)
        } catch is CancellationError { }
        catch { }
    }

    private func switchRelative(_ offset: Int) async {
        guard let snapshot = relativeSnapshot(offset) else { return }
        await switchChannel(to: snapshot)
    }

    private func relativeSnapshot(_ offset: Int) -> IOSJellyfinLiveChannelSnapshot? {
        guard let index = context.lineup.firstIndex(where: { $0.channel.id == activeChannel.id }) else { return nil }
        let target = index + offset
        guard context.lineup.indices.contains(target) else { return nil }
        return context.lineup[target]
    }

    /// Resolve the replacement before stopping the active stream. This keeps a
    /// healthy channel playing during server negotiation and makes failover feel
    /// like a channel change rather than a full player restart.
    private func switchChannel(to snapshot: IOSJellyfinLiveChannelSnapshot) async {
        guard snapshot.channel.id != activeChannel.id, !isSwitchingChannel else { return }
        isSwitchingChannel = true
        defer { isSwitchingChannel = false; restartAutoHide() }
        guard let resolved = await context.provider.resolveStream(for: snapshot.channel) else { return }

        let previous = activeStream
        player.stop()
        activeChannel = snapshot.channel
        activeProgram = snapshot.currentProgram
        activeStream = resolved
        await context.provider.endStream(previous)
        await load(resolved)
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

private struct IOSJellyfinMiniGuideSheet: View {
    let snapshots: [IOSJellyfinLiveChannelSnapshot]
    let activeChannelID: String
    let onSelect: (IOSJellyfinLiveChannelSnapshot) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var visible: [IOSJellyfinLiveChannelSnapshot] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return snapshots }
        return snapshots.filter {
            $0.channel.name.lowercased().contains(term)
                || $0.currentProgram?.title.lowercased().contains(term) == true
        }
    }

    var body: some View {
        NavigationStack {
            List(visible) { snapshot in
                Button { onSelect(snapshot) } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: snapshot.channel.logoURL) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFit() }
                            else { Image(systemName: "play.tv") }
                        }
                        .frame(width: 50, height: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.channel.name).font(.headline).lineLimit(1)
                            if let program = snapshot.currentProgram {
                                Text(program.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if snapshot.channel.id == activeChannelID {
                            Image(systemName: "waveform").foregroundStyle(.cyan)
                        } else {
                            Image(systemName: "play.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Channels or programmes")
            .navigationTitle("Mini Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
