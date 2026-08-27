// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct IOSJellyfinContainerView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession

    var body: some View {
        if case .restoring = jellyfin.state {
            IOSJellyfinLaunchView()
        } else if jellyfin.isConfigured {
            IOSJellyfinRootView()
        } else {
            // Keep one stable sign-in view while the state moves through
            // signedOut -> connecting -> failed. Replacing this branch used
            // to trigger onDisappear and cancel authentication immediately.
            IOSJellyfinSignInView()
        }
    }
}

private struct IOSJellyfinLaunchView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(red: 0.03, green: 0.10, blue: 0.15)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.cyan)
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct IOSJellyfinSignInView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @AppStorage("jellyfin.lastServerURL") private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var operation: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.01, green: 0.16, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("Connect Jellyfin")
                        .font(.largeTitle.bold())

                    if let code = jellyfin.quickConnectCode {
                        IOSJellyfinQuickConnectCodeView(
                            code: code,
                            payloadURL: jellyfin.quickConnectPayloadURL
                        )
                        .transition(.scale.combined(with: .opacity))

                        Button("Cancel Quick Connect", systemImage: "xmark") {
                            operation?.cancel()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        VStack(spacing: 14) {
                            TextField("Server address", text: $server)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .onSubmit(connect)
                        }
                        .textFieldStyle(.plain)
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.14)) }

                        Button(action: connect) {
                            Label(isBusy ? "Connecting…" : "Connect", systemImage: "arrow.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isBusy || server.isEmpty || username.isEmpty)

                        Button("Quick Connect", systemImage: "qrcode", action: quickConnect)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(isBusy || server.isEmpty)

                        if IOSJellyfinPasskeyCoordinator.isAvailableInThisBuild {
                            Button("Sign in with Passkey", systemImage: "person.badge.key.fill", action: passkey)
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .disabled(isBusy || server.isEmpty)
                        }

                        IOSBackendPicker()
                            .pickerStyle(.segmented)
                            .padding(.top, 8)
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.vertical, 54)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { operation?.cancel() }
    }

    private var isBusy: Bool {
        if case .connecting = jellyfin.state { return true }
        return false
    }

    private func connect() {
        guard operation == nil, !server.isEmpty, !username.isEmpty else { return }
        let submittedPassword = password
        password = ""
        error = nil
        operation = Task {
            defer { operation = nil }
            do { try await jellyfin.signIn(server: server, username: username, password: submittedPassword) }
            catch is CancellationError { }
            catch { self.error = IOSJellyfinSession.message(for: error) }
        }
    }

    private func quickConnect() {
        guard operation == nil, !server.isEmpty else { return }
        password = ""
        error = nil
        operation = Task {
            defer { operation = nil }
            do { try await jellyfin.quickConnect(server: server) }
            catch is CancellationError { }
            catch { self.error = IOSJellyfinSession.message(for: error) }
        }
    }

    private func passkey() {
        guard operation == nil, !server.isEmpty else { return }
        password = ""
        error = nil
        operation = Task {
            defer { operation = nil }
            do { try await jellyfin.passkeySignIn(server: server) }
            catch is CancellationError { }
            catch { self.error = IOSJellyfinSession.message(for: error) }
        }
    }
}

struct IOSJellyfinRootView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = "home"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: "home") { IOSJellyfinHomeView() }
            Tab("Movies", systemImage: "film.stack.fill", value: "movies") {
                IOSJellyfinCatalogView(kind: .movies)
            }
            Tab("TV Shows", systemImage: "tv.fill", value: "shows") {
                IOSJellyfinCatalogView(kind: .shows)
            }
            Tab("Live TV", systemImage: "play.tv.fill", value: "live") { IOSJellyfinLiveTVView() }
            Tab("Search", systemImage: "magnifyingglass", value: "search", role: .search) {
                IOSJellyfinSearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await jellyfin.refreshContinueWatching() }
        }
    }
}

struct IOSJellyfinHomeView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var mode = HomeMode.home

    private enum HomeMode: String, CaseIterable, Identifiable {
        case home = "Home"
        case discover = "Discover"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if jellyfin.homeHubs.isEmpty, jellyfin.isRefreshing {
                    IOSJellyfinSkeletonHome()
                } else if jellyfin.homeHubs.isEmpty {
                    ContentUnavailableView(
                        "Your Jellyfin home is ready",
                        systemImage: "play.rectangle.on.rectangle",
                        description: Text(stateMessage)
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            Picker("Browse", selection: $mode) {
                                ForEach(HomeMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)

                            if let hero = visibleHubs.flatMap(\.items).first {
                                IOSJellyfinHero(item: hero)
                            }
                            ForEach(visibleHubs) { hub in
                                if hub.title == "Continue Watching" {
                                    IOSJellyfinContinueWatchingShelf(items: hub.items)
                                } else {
                                    IOSJellyfinShelf(title: hub.title, items: hub.items)
                                }
                            }
                            if mode == .discover {
                                IOSJellyfinDiscoveryGenreShelves()
                            }
                        }
                        .padding(.bottom, 30)
                    }
                    .refreshable { await jellyfin.refresh() }
                    .task { await jellyfin.refreshContinueWatching() }
                }
            }
            .navigationTitle(mode.rawValue)
            .toolbar { IOSJellyfinAccountToolbar() }
            .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
        }
    }

    private var visibleHubs: [MediaHub] {
        switch mode {
        case .home:
            let values = jellyfin.homeHubs.filter {
                $0.title == "Continue Watching"
                    || $0.title == "Top Picks for You"
                    || $0.title == "Director’s Picks"
                    || $0.title.hasPrefix("Favorite")
            }
            return values.isEmpty ? jellyfin.homeHubs : values
        case .discover:
            let values = jellyfin.homeHubs.filter {
                $0.title != "Continue Watching" && $0.title != "Next Up"
            }
            return values.isEmpty ? jellyfin.homeHubs : values
        }
    }

    private var stateMessage: String {
        if case .failed(let message) = jellyfin.state { return message }
        return "Pull to refresh your libraries."
    }
}

private struct IOSJellyfinDiscoveryGenreShelves: View {
    private struct Section: Identifiable {
        let kind: JellyfinCatalogKind
        let genre: JellyfinCatalogGenre
        var id: String { "\(kind.rawValue):\(genre.id)" }
        var title: String { "\(genre.name) \(kind == .movies ? "Movies" : "Shows")" }
    }

    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var sections: [Section] = []

    var body: some View {
        ForEach(sections) { section in
            IOSJellyfinDiscoveryGenreShelf(
                title: section.title,
                request: JellyfinCatalogQuery(
                    kind: section.kind,
                    genre: section.genre.name,
                    sort: .ratingDesc
                )
            )
        }
        .task {
            guard sections.isEmpty else { return }
            async let movieRequest = jellyfin.genres(for: .movies)
            async let showRequest = jellyfin.genres(for: .shows)
            let movieGenres = (try? await movieRequest) ?? []
            let showGenres = (try? await showRequest) ?? []
            let preferred = [
                "Action", "Drama", "Comedy", "Crime", "Documentary",
                "Family", "Animation", "Science Fiction", "Adventure"
            ]
            let movies = prioritized(movieGenres, names: preferred).prefix(3).map {
                Section(kind: .movies, genre: $0)
            }
            let shows = prioritized(showGenres, names: preferred).prefix(3).map {
                Section(kind: .shows, genre: $0)
            }
            sections = interleaved(Array(movies), Array(shows))
        }
    }

    private func prioritized(
        _ genres: [JellyfinCatalogGenre],
        names: [String]
    ) -> [JellyfinCatalogGenre] {
        let ordered = names.compactMap { preferred in
            genres.first { $0.name.localizedCaseInsensitiveCompare(preferred) == .orderedSame }
        }
        let selected = Set(ordered.map(\.id))
        return ordered + genres.filter { !selected.contains($0.id) }
    }

    private func interleaved(_ first: [Section], _ second: [Section]) -> [Section] {
        var output: [Section] = []
        for index in 0..<max(first.count, second.count) {
            if first.indices.contains(index) { output.append(first[index]) }
            if second.indices.contains(index) { output.append(second[index]) }
        }
        return output
    }
}

private struct IOSJellyfinDiscoveryGenreShelf: View {
    let title: String
    let request: JellyfinCatalogQuery

    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var items: [MediaItem] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                IOSJellyfinShelf(title: title, items: items)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .task(id: request) {
            guard items.isEmpty else { return }
            if let page = try? await jellyfin.catalog(request, pageSize: 24),
               !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.24)) { items = page.items }
            }
        }
    }
}

private struct IOSJellyfinLibrariesView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession

    var body: some View {
        NavigationStack {
            List(jellyfin.libraries) { library in
                NavigationLink(value: library) {
                    Label(library.title, systemImage: library.icon)
                }
            }
            .overlay {
                if jellyfin.libraries.isEmpty {
                    ContentUnavailableView("No libraries", systemImage: "rectangle.stack")
                }
            }
            .navigationTitle("Libraries")
            .navigationDestination(for: MediaLibrary.self) { IOSJellyfinLibraryView(library: $0) }
        }
    }
}

private struct IOSJellyfinLibraryView: View {
    let library: MediaLibrary
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var items: [MediaItem] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 14)], spacing: 20) {
                ForEach(items) { item in
                    NavigationLink(value: item) { IOSJellyfinPosterCard(item: item) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if items.isEmpty, error == nil { ProgressView() }
            if let error { ContentUnavailableView("Couldn’t load library", systemImage: "exclamationmark.triangle", description: Text(error)) }
        }
        .navigationTitle(library.title)
        .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        do { items = try await jellyfin.items(in: library, force: force); error = nil }
        catch { self.error = IOSJellyfinSession.message(for: error) }
    }
}

struct IOSJellyfinSearchView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 14)], spacing: 20) {
                    ForEach(results) { item in
                        NavigationLink(value: item) { IOSJellyfinPosterCard(item: item) }.buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .overlay {
                if query.isEmpty { ContentUnavailableView("Search Jellyfin", systemImage: "magnifyingglass") }
                if let error { ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error)) }
            }
            .navigationTitle("Search")
            .toolbar { IOSJellyfinAccountToolbar() }
            .searchable(text: $query, prompt: "Movies, shows and episodes")
            .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
            .task(id: query) { await search() }
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count > 1 else { results = []; error = nil; return }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        do { results = try await jellyfin.search(term); error = nil }
        catch { self.error = IOSJellyfinSession.message(for: error) }
    }
}

struct IOSJellyfinSettingsView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession

    var body: some View {
        NavigationStack {
            Form {
                Section("Media provider") { IOSBackendPicker() }
                Section("Jellyfin") {
                    LabeledContent("Status", value: jellyfin.isConfigured ? "Connected" : "Not connected")
                    if let user = jellyfin.userName { LabeledContent("Profile", value: user) }
                    if let server = jellyfin.serverName { LabeledContent("Server", value: server) }
                    Button("Refresh Jellyfin", systemImage: "arrow.clockwise") { Task { await jellyfin.refresh() } }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await jellyfin.signOut() }
                    }
                }
                Section("Account security") {
                    NavigationLink {
                        IOSJellyfinSecuritySettingsView()
                    } label: {
                        Label(
                            IOSJellyfinPasskeyCoordinator.isAvailableInThisBuild
                                ? "Passkeys & Face ID"
                                : "Face ID & App Lock",
                            systemImage: "faceid"
                        )
                    }
                    NavigationLink {
                        IOSJellyfinQuickConnectAuthorizerView()
                    } label: {
                        Label("Connect another device", systemImage: "qrcode.viewfinder")
                    }
                }
                Section("Preferences") {
                    NavigationLink {
                        IOSJellyfinPlaybackSettingsView()
                    } label: {
                        Label("Playback & languages", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        IOSJellyfinLiveTVSettingsView()
                    } label: {
                        Label("Live TV", systemImage: "play.tv")
                    }
                    NavigationLink {
                        IOSJellyfinAppearanceSettingsView()
                    } label: {
                        Label("Discovery & appearance", systemImage: "sparkles")
                    }
                    NavigationLink {
                        IOSJellyfinStorageSettingsView()
                    } label: {
                        Label("Storage & cache", systemImage: "externaldrive")
                    }
                }
                Section("Playback") {
                    LabeledContent("Engine", value: "AetherEngine")
                    LabeledContent("Direct play", value: "Preferred")
                    Text("Jellyfin negotiates direct play, remux, or HLS. AirPlay is available whenever the native HLS path is active.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section { NavigationLink("Licenses & Legal") { IOSLicensesView() } }
            }
            .navigationTitle("Settings")
        }
    }
}

struct IOSJellyfinHero: View {
    let item: MediaItem

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                IOSJellyfinArtwork(url: item.artwork.backdrop ?? item.artwork.poster, aspectRatio: 16 / 9)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.largeTitle.bold()).lineLimit(2)
                    HStack { if let year = item.year { Text(String(year)) }; if let duration = item.durationFormatted { Text(duration) } }
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.12)) }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        // AsyncImage may otherwise retain the previous successful image while
        // a new Home/Discover hero starts loading. Re-key the complete hero so
        // navigation never flashes artwork from another title.
        .id(item.ref)
    }
}

struct IOSJellyfinShelf: View {
    let title: String
    let items: [MediaItem]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var posterWidth: CGFloat { horizontalSizeClass == .regular ? 190 : 156 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            IOSJellyfinPosterCard(item: item, width: posterWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// A distinct landscape rail for in-progress playback. The card mirrors the
/// hierarchy of Apple's TV app while retaining Jellyfin as the sole source of
/// progress, so iPhone, iPad, Apple TV, web and third-party clients converge on
/// the same episode and timestamp.
struct IOSJellyfinContinueWatchingShelf: View {
    let items: [MediaItem]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var cardWidth: CGFloat { horizontalSizeClass == .regular ? 360 : 292 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(.title2.bold())
                .padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            IOSJellyfinContinueWatchingCard(item: item, width: cardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct IOSJellyfinContinueWatchingCard: View {
    let item: MediaItem
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            IOSJellyfinArtwork(url: artworkURL, aspectRatio: 16 / 9)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.32),
                    .init(color: .black.opacity(0.38), location: 0.62),
                    .init(color: .black.opacity(0.94), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(item.continueWatchingTitle)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                if let subtitle = item.continueWatchingSubtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }
                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                    if let label = item.continueWatchingProgressLabel {
                        Text(label).lineLimit(1)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                if let progress = item.watchProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .accessibilityLabel("Playback progress")
                        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
                }
            }
            .padding(14)
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Opens this title at your saved position")
    }

    private var artworkURL: URL? {
        item.artwork.thumbnail
            ?? item.artwork.backdrop
            ?? item.grandparentArtwork?.backdrop
            ?? item.parentArtwork?.backdrop
            ?? item.artwork.poster
            ?? item.grandparentArtwork?.poster
    }

    private var accessibilityTitle: String {
        [item.continueWatchingTitle, item.continueWatchingSubtitle, item.continueWatchingProgressLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

struct IOSJellyfinPosterCard: View {
    let item: MediaItem
    var width: CGFloat? = 156

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IOSJellyfinArtwork(url: item.artwork.poster ?? item.artwork.thumbnail, aspectRatio: 2 / 3)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .frame(width: width)
                .overlay(alignment: .bottom) {
                    if let progress = item.watchProgress {
                        ProgressView(value: progress).tint(.cyan).padding(.horizontal, 6).padding(.bottom, 5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.userState.isFavorite {
                        Image(systemName: "heart.fill").foregroundStyle(.red).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                .frame(width: width, alignment: .leading)
            if let year = item.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct IOSJellyfinArtwork: View {
    let url: URL?
    let aspectRatio: CGFloat

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.24))) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill().transition(.opacity)
            case .failure: placeholder
            default: placeholder.redacted(reason: .placeholder)
            }
        }
        .id(url?.absoluteString ?? "jellyfin-artwork-placeholder")
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
        .background(Color.white.opacity(0.05))
    }

    private var placeholder: some View {
        ZStack { Color.white.opacity(0.06); Image(systemName: "film").foregroundStyle(.secondary) }
    }
}

private struct IOSJellyfinSkeletonHome: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.07)).frame(height: 320)
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)).frame(width: 180, height: 24)
                    HStack { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.06)).frame(width: 156, height: 234) } }
                }
            }
            .padding()
            .redacted(reason: .placeholder)
        }
    }
}

private extension MediaLibrary {
    var icon: String {
        switch kind {
        case .movies: return "film.stack"
        case .shows: return "tv"
        case .music: return "music.note"
        case .photos: return "photo.stack"
        case .liveTV: return "play.tv"
        case .mixed: return "rectangle.stack"
        }
    }
}
