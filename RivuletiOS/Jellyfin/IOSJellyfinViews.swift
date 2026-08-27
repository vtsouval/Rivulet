// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
#if !targetEnvironment(macCatalyst)
import VisionKit
#endif

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
    @State private var showsPairingScanner = false
    @State private var pendingPairing: JellyfinDevicePairingPayload?

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

                        #if !targetEnvironment(macCatalyst)
                        if DataScannerViewController.isSupported,
                           DataScannerViewController.isAvailable {
                            Button("Scan Bonfire Pairing QR", systemImage: "qrcode.viewfinder") {
                                showsPairingScanner = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(isBusy)
                        }
                        #endif

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
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $showsPairingScanner) {
            IOSJellyfinQRCodeScannerView { value in
                showsPairingScanner = false
                preparePairing(value)
            }
        }
        #endif
        .confirmationDialog(
            "Sign in with this pairing?",
            isPresented: Binding(
                get: { pendingPairing != nil },
                set: { if !$0 { pendingPairing = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sign In") { claimPairing() }
            Button("Cancel", role: .cancel) { pendingPairing = nil }
        } message: {
            Text(pairingConfirmationMessage)
        }
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

    private var pairingConfirmationMessage: String {
        guard let pendingPairing else { return "" }
        let host = pendingPairing.serverURL.host ?? pendingPairing.serverURL.absoluteString
        return "Use the single-use Bonfire pairing to sign in to \(host)."
    }

    private func preparePairing(_ scannedValue: String) {
        do {
            let trimmed = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme != nil else {
                throw JellyfinAPIError.invalidResponse
            }
            pendingPairing = try JellyfinDevicePairingPayload(url: url)
            error = nil
        } catch {
            pendingPairing = nil
            self.error = "This Bonfire pairing QR is invalid or expired."
        }
    }

    private func claimPairing() {
        guard operation == nil, let payload = pendingPairing else { return }
        pendingPairing = nil
        password = ""
        error = nil
        operation = Task {
            defer { operation = nil }
            do { try await jellyfin.claimDevicePairing(payload) }
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
                            if let hero = heroItem {
                                IOSJellyfinHero(item: hero)
                            }
                            ForEach(visibleHubs) { hub in
                                if hub.title == "Continue Watching" {
                                    IOSJellyfinContinueWatchingShelf(items: hub.items)
                                } else if let request = JellyfinHomeCarouselContinuation.request(
                                    for: hub.title
                                ) {
                                    IOSJellyfinPagedCatalogShelf(
                                        title: hub.title,
                                        request: request,
                                        seedItems: hub.items
                                    )
                                } else {
                                    IOSJellyfinShelf(title: hub.title, items: hub.items)
                                }
                            }
                            IOSJellyfinDiscoveryGenreShelves()
                        }
                        .padding(.bottom, 30)
                    }
                    .refreshable { await jellyfin.refresh() }
                    .task { await jellyfin.refreshContinueWatching() }
                }
            }
            .navigationTitle("Home")
            .toolbar { IOSJellyfinAccountToolbar() }
            .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
        }
    }

    private var visibleHubs: [MediaHub] {
        // The paged rails below replace the short, synthesized genre hubs. All
        // personalized, editorial, studio, watchlist and favorite hubs remain
        // together in one streamlined Home/Discover surface.
        jellyfin.homeHubs.filter {
            $0.title != "Next Up" && !$0.id.contains(":discover:")
        }
    }

    private var heroItem: MediaItem? {
        let preferred = ["Top Picks for You", "Director’s Picks", "Trending Movies", "Trending TV Shows"]
        for title in preferred {
            if let item = visibleHubs.first(where: { $0.title == title })?.items.first {
                return item
            }
        }
        return visibleHubs.lazy.flatMap(\.items).first { $0.kind == .movie || $0.kind == .show }
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
            let movies = prioritized(movieGenres, names: preferred).prefix(4).map {
                Section(kind: .movies, genre: $0)
            }
            let shows = prioritized(showGenres, names: preferred).prefix(4).map {
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

    var body: some View {
        IOSJellyfinPagedCatalogShelf(title: title, request: request)
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
        Group {
            if let catalogKind = library.catalogKind {
                ScrollView {
                    IOSJellyfinPagedCatalogShelf(
                        title: "Recently Added",
                        request: JellyfinCatalogQuery(
                            kind: catalogKind,
                            libraryID: library.id,
                            sort: .addedAtDesc
                        )
                    )
                    .padding(.vertical)
                }
            } else {
                ScrollView {
                    IOSJellyfinShelf(title: library.title, items: items)
                        .padding(.vertical)
                }
            }
        }
        .overlay {
            if library.catalogKind == nil {
                if items.isEmpty, error == nil { ProgressView() }
                if let error {
                    ContentUnavailableView(
                        "Couldn’t load library",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                }
            }
        }
        .navigationTitle(library.title)
        .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
        .task {
            guard library.catalogKind == nil else { return }
            await load()
        }
        .refreshable {
            guard library.catalogKind == nil else { return }
            await load(force: true)
        }
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
    @State private var completedTerm: String?
    @State private var isSearching = false
    @State private var error: String?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sections: MediaSearchSections { MediaSearchSections(results) }

    var body: some View {
        NavigationStack {
            Group {
                if term.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text("Find movies and TV shows.")
                    )
                } else if term.count < 2 {
                    ContentUnavailableView(
                        "Keep typing",
                        systemImage: "text.cursor",
                        description: Text("Enter at least two characters.")
                    )
                } else if isSearching && results.isEmpty {
                    IOSJellyfinSearchLoadingView()
                        .transition(.opacity)
                } else if error != nil {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Search is temporarily unavailable")
                            .font(.title3.bold())
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            Task { await search(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if completedTerm == term && sections.isEmpty {
                    ContentUnavailableView.search(text: term)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            if !sections.movies.isEmpty {
                                IOSJellyfinShelf(title: "Movies", items: sections.movies)
                            }
                            if !sections.shows.isEmpty {
                                IOSJellyfinShelf(title: "TV Shows", items: sections.shows)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.snappy(duration: 0.3), value: isSearching)
            .animation(.snappy(duration: 0.3), value: completedTerm)
            .navigationTitle("Search")
            .toolbar { IOSJellyfinAccountToolbar() }
            .searchable(text: $query, prompt: "Movies and TV shows")
            .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
            .task(id: query) { await search() }
        }
    }

    private func search(force: Bool = false) async {
        let requestedTerm = term
        guard requestedTerm.count >= 2 else {
            results = []
            completedTerm = nil
            error = nil
            isSearching = false
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            results = []
            completedTerm = nil
            error = nil
            isSearching = true
        }

        if !force {
            do { try await Task.sleep(for: .milliseconds(220)) }
            catch { return }
        }
        guard !Task.isCancelled, term == requestedTerm else { return }

        do {
            let fetched = try await jellyfin.search(requestedTerm)
            try Task.checkCancellation()
            guard term == requestedTerm else { return }
            withAnimation(.snappy(duration: 0.32)) {
                results = fetched
                completedTerm = requestedTerm
                error = nil
                isSearching = false
            }
        } catch is CancellationError {
            // `.task(id:)` cancels the previous request as the user types.
            // Cancellation is normal control flow, never a visible error.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Some URLSession paths surface cancellation as URLError.
        } catch {
            guard !Task.isCancelled, term == requestedTerm else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.error = IOSJellyfinSession.message(for: error)
                completedTerm = requestedTerm
                isSearching = false
            }
        }
    }
}

private struct IOSJellyfinSearchLoadingView: View {
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 72, height: 72)
                    .overlay { Circle().stroke(.white.opacity(0.14), lineWidth: 1) }
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .scaleEffect(isPulsing ? 1.08 : 0.92)
                    .opacity(isPulsing ? 1 : 0.62)
            }
            Text("Searching")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Searching")
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
    var onItemAppear: ((MediaItem) -> Void)? = nil
    var isLoadingMore = false
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
                        .onAppear { onItemAppear?(item) }
                    }
                    if isLoadingMore {
                        IOSJellyfinPosterPlaceholder(width: posterWidth)
                            .transition(.opacity)
                            .accessibilityLabel("Loading more \(title.lowercased())")
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        }
    }
}

/// A stable horizontal placeholder keeps the page geometry unchanged while a
/// catalog's first page or next page is arriving. This avoids the temporary
/// vertical-grid flash that previously appeared before the real carousel.
struct IOSJellyfinShelfSkeleton: View {
    let title: String
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var posterWidth: CGFloat { horizontalSizeClass == .regular ? 190 : 156 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        IOSJellyfinPosterPlaceholder(width: posterWidth)
                    }
                }
                .padding(.horizontal)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

private struct IOSJellyfinPosterPlaceholder: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.white.opacity(0.07))
                .frame(width: width, height: width * 1.5)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.07))
                .frame(width: width * 0.72, height: 14)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.05))
                .frame(width: width * 0.34, height: 10)
        }
    }
}

/// A cache-backed, endlessly paged shelf shared by Home and the movie/show
/// catalogs. Only the first page blocks appearance; reaching the final few
/// cards quietly appends the next page without replacing or flashing the rail.
struct IOSJellyfinPagedCatalogShelf: View {
    let title: String
    let request: JellyfinCatalogQuery
    var seedItems: [MediaItem] = []

    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var items: [MediaItem] = []
    @State private var hasMore = true
    @State private var isLoadingInitial = true
    @State private var isLoadingMore = false

    var body: some View {
        Group {
            if !items.isEmpty {
                IOSJellyfinShelf(
                    title: title,
                    items: items,
                    onItemAppear: loadMoreIfNeeded,
                    isLoadingMore: isLoadingMore
                )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if isLoadingInitial {
                IOSJellyfinShelfSkeleton(title: title)
            }
        }
        .task(id: request) { await loadInitial() }
        .onChange(of: seedItems.map(\.ref)) { _, _ in
            // Home can refresh a personalized seed while the continuation
            // query remains identical. Merge it without resetting scroll or
            // discarding pages the user has already loaded.
            items = Self.unique(seedItems + items)
        }
    }

    private func loadInitial() async {
        guard items.isEmpty else { return }
        items = Self.unique(seedItems)
        isLoadingInitial = items.isEmpty
        defer { isLoadingInitial = false }
        guard let page = try? await jellyfin.catalog(request, pageSize: 30),
              !Task.isCancelled else { return }
        items = Self.unique(items + page.items)
        hasMore = page.hasMore
    }

    private func loadMoreIfNeeded(_ item: MediaItem) {
        guard hasMore, !isLoadingMore,
              let index = items.firstIndex(where: { $0.ref == item.ref }),
              index >= items.count - 7 else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await jellyfin.catalog(request, loadMore: true, pageSize: 30),
                  !Task.isCancelled else { return }
            items = Self.unique(items + page.items)
            hasMore = page.hasMore
        }
    }

    private static func unique(_ values: [MediaItem]) -> [MediaItem] {
        var seen = Set<MediaItemRef>()
        return values.filter { seen.insert($0.ref).inserted }
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
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
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
    var catalogKind: JellyfinCatalogKind? {
        switch kind {
        case .movies: .movies
        case .shows: .shows
        default: nil
        }
    }

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
