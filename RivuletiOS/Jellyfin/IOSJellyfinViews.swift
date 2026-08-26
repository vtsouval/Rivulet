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

                    if let code = jellyfin.quickConnectCode {
                        VStack(spacing: 8) {
                            Text(code).font(.system(.largeTitle, design: .monospaced, weight: .bold))
                            Text("Approve this code in Jellyfin")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                            .multilineTextAlignment(.center)
                    }

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
    @State private var selectedTab = "home"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: "home") { IOSJellyfinHomeView() }
            Tab("Libraries", systemImage: "rectangle.stack.fill", value: "libraries") { IOSJellyfinLibrariesView() }
            Tab("Search", systemImage: "magnifyingglass", value: "search") { IOSJellyfinSearchView() }
            Tab("Live TV", systemImage: "play.tv.fill", value: "live") { IOSJellyfinLiveTVView() }
            Tab("Settings", systemImage: "gearshape.fill", value: "settings") { IOSJellyfinSettingsView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

private struct IOSJellyfinHomeView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession

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
                            if let hero = jellyfin.homeHubs.flatMap(\.items).first {
                                IOSJellyfinHero(item: hero)
                            }
                            ForEach(jellyfin.homeHubs) { hub in
                                IOSJellyfinShelf(title: hub.title, items: hub.items)
                            }
                        }
                        .padding(.bottom, 30)
                    }
                    .refreshable { await jellyfin.refresh() }
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
        }
    }

    private var stateMessage: String {
        if case .failed(let message) = jellyfin.state { return message }
        return "Pull to refresh your libraries."
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

private struct IOSJellyfinSearchView: View {
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

private struct IOSJellyfinSettingsView: View {
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
                }
                Section("Preferences") {
                    NavigationLink {
                        IOSJellyfinPlaybackSettingsView()
                    } label: {
                        Label("Playback & languages", systemImage: "slider.horizontal.3")
                    }
                }
                Section("Playback") {
                    LabeledContent("Engine", value: "AetherEngine")
                    LabeledContent("Direct play", value: "Preferred")
                    Text("Jellyfin negotiates direct play, remux, or HLS without exposing server or debrid credentials in media URLs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section { NavigationLink("Licenses & Legal") { IOSLicensesView() } }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct IOSJellyfinHero: View {
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
    }
}

private struct IOSJellyfinShelf: View {
    let title: String
    let items: [MediaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { IOSJellyfinPosterCard(item: item) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct IOSJellyfinPosterCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IOSJellyfinArtwork(url: item.artwork.poster ?? item.artwork.thumbnail, aspectRatio: 2 / 3)
                .frame(width: 138)
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
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(width: 138, alignment: .leading)
            if let year = item.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct IOSJellyfinArtwork: View {
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
                    HStack { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.06)).frame(width: 138, height: 207) } }
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
