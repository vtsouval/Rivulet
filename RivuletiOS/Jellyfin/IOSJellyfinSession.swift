// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation

/// Main-actor adapter between the shared Jellyfin provider and SwiftUI.
/// Passwords never leave the sign-in task; only Jellyfin's revocable token is
/// persisted by `JellyfinSessionStore` in Keychain.
@MainActor
final class IOSJellyfinSession: ObservableObject {
    enum State: Equatable {
        case restoring
        case signedOut
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .restoring
    @Published private(set) var libraries: [MediaLibrary] = []
    @Published private(set) var homeHubs: [MediaHub] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var quickConnectCode: String?

    private(set) var provider: JellyfinProvider?
    private(set) var liveTVProvider: JellyfinLiveTVProvider?
    private var libraryCache: [String: [MediaItem]] = [:]
    private var detailCache: [MediaItemRef: MediaItemDetail] = [:]
    private var childrenCache: [MediaItemRef: [MediaItem]] = [:]
    private var relatedCache: [MediaItemRef: [MediaItem]] = [:]
    private var restoreTask: Task<Void, Never>?

    var isConfigured: Bool { provider != nil }
    var userName: String? { provider?.session.user.name }
    var serverName: String? { provider?.session.serverURL.host }

    init() {
        restoreTask = Task { [weak self] in
            await self?.restore()
        }
    }

    deinit { restoreTask?.cancel() }

    func restore() async {
        guard let session = JellyfinSessionStore.shared.currentSession else {
            state = .signedOut
            return
        }

        // Attach immediately so a valid remembered session can paint cached
        // navigation without waiting for the validation round trip. An auth
        // rejection below still removes it from Keychain before showing UI.
        do {
            try attach(session)
        } catch {
            state = .failed(Self.message(for: error))
            return
        }

        let valid = await JellyfinSessionStore.shared.validateCurrentSession()
        if valid, let refreshed = JellyfinSessionStore.shared.currentSession {
            do {
                try attach(refreshed)
                await refresh()
            } catch {
                state = .failed(Self.message(for: error))
            }
        } else if JellyfinSessionStore.shared.currentSession == nil {
            reset(to: .signedOut)
        } else {
            // Connectivity failures retain the authenticated offline session.
            state = .connected
            await refresh()
        }
    }

    func signIn(server: String, username: String, password: String) async throws {
        state = .connecting
        do {
            let transport = try JellyfinTransport(
                serverURL: server,
                clientIdentity: JellyfinSessionStore.clientIdentity()
            )
            let auth = JellyfinAuthClient(transport: transport)
            _ = try await auth.publicSystemInfo()
            let session = try await auth.authenticate(username: username, password: password)
            try await JellyfinSessionStore.shared.persist(session)
            UserDefaults.standard.set(session.serverURL.absoluteString, forKey: "jellyfin.lastServerURL")
            try attach(session)
            await refresh()
        } catch {
            state = .failed(Self.message(for: error))
            throw error
        }
    }

    func quickConnect(server: String) async throws {
        state = .connecting
        quickConnectCode = nil
        do {
            let transport = try JellyfinTransport(
                serverURL: server,
                clientIdentity: JellyfinSessionStore.clientIdentity()
            )
            let auth = JellyfinAuthClient(transport: transport)
            guard try await auth.isQuickConnectEnabled() else {
                throw JellyfinAPIError.forbidden(message: "Quick Connect is disabled on this server.")
            }
            let started = try await auth.startQuickConnect()
            quickConnectCode = started.code
            let deadline = Date().addingTimeInterval(300)
            var status = started
            while !status.authenticated {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    throw JellyfinAPIError.unauthorized(message: "Quick Connect expired. Try again.")
                }
                try await Task.sleep(for: .seconds(2))
                status = try await auth.pollQuickConnect(secret: started.secret)
            }
            let session = try await auth.authenticateWithQuickConnect(secret: started.secret)
            try await JellyfinSessionStore.shared.persist(session)
            UserDefaults.standard.set(session.serverURL.absoluteString, forKey: "jellyfin.lastServerURL")
            quickConnectCode = nil
            try attach(session)
            await refresh()
        } catch {
            quickConnectCode = nil
            state = .failed(Self.message(for: error))
            throw error
        }
    }

    func signOut() async {
        await JellyfinSessionStore.shared.signOut()
        reset(to: .signedOut)
    }

    func refresh() async {
        guard let provider else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let fetchedLibraries = provider.libraries()
            async let fetchedHubs = provider.hubs()
            let (libraries, hubs) = try await (fetchedLibraries, fetchedHubs)
            self.libraries = libraries
            self.homeHubs = hubs
            state = .connected

            // Warm the first library pages after the visible home data lands.
            // This makes the first tab switch immediate without delaying home.
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.prefetch(libraries: libraries)
            }
        } catch {
            if homeHubs.isEmpty, libraries.isEmpty {
                state = .failed(Self.message(for: error))
            }
        }
    }

    func items(in library: MediaLibrary, force: Bool = false) async throws -> [MediaItem] {
        if !force, let cached = libraryCache[library.id] { return cached }
        guard let provider else { throw MediaProviderError.unauthorized }
        let result = try await provider.items(
            in: library,
            sort: .addedAtDesc,
            page: Page(offset: 0, limit: 120)
        )
        libraryCache[library.id] = result.items
        return result.items
    }

    func search(_ query: String) async throws -> [MediaItem] {
        guard let provider else { throw MediaProviderError.unauthorized }
        return try await provider.search(query)
    }

    func detail(for item: MediaItem, force: Bool = false) async throws -> MediaItemDetail {
        if !force, let cached = detailCache[item.ref] { return cached }
        guard let provider else { throw MediaProviderError.unauthorized }
        let detail = try await provider.fullDetail(for: item.ref)
        detailCache[item.ref] = detail
        return detail
    }

    func children(of item: MediaItem, force: Bool = false) async throws -> [MediaItem] {
        if !force, let cached = childrenCache[item.ref] { return cached }
        guard let provider else { throw MediaProviderError.unauthorized }
        let children = try await provider.children(of: item.ref)
        childrenCache[item.ref] = children
        return children
    }

    func episodes(of show: MediaItem, force: Bool = false) async throws -> [MediaItem] {
        if !force, let cached = childrenCache[show.ref], cached.contains(where: { $0.kind == .episode }) {
            return cached
        }
        guard let provider else { throw MediaProviderError.unauthorized }
        let episodes = try await provider.allEpisodes(of: show.ref)
        childrenCache[show.ref] = episodes
        return episodes
    }

    func related(to item: MediaItem, force: Bool = false) async throws -> [MediaItem] {
        if !force, let cached = relatedCache[item.ref] { return cached }
        guard let provider else { throw MediaProviderError.unauthorized }
        let related = try await provider.relatedItems(for: item.ref)
        relatedCache[item.ref] = related
        return related
    }

    func resolve(_ item: MediaItem, sourceID: String? = nil) async throws -> StreamInfo {
        guard let provider else { throw MediaProviderError.unauthorized }
        return try await provider.resolveStream(for: item.ref, sourceID: sourceID)
    }

    func setFavorite(_ item: MediaItem, enabled: Bool) async throws {
        guard let provider else { throw MediaProviderError.unauthorized }
        try await provider.setFavorite(item.ref, enabled: enabled)
        detailCache[item.ref] = nil
    }

    func isOnWatchlist(_ item: MediaItem) async -> Bool {
        await provider?.isOnWatchlist(item.ref) ?? false
    }

    func setWatchlist(_ item: MediaItem, enabled: Bool) async throws {
        guard let provider else { throw MediaProviderError.unauthorized }
        if enabled {
            try await provider.addToWatchlist(item.ref)
        } else {
            try await provider.removeFromWatchlist(item.ref)
        }
    }

    private func attach(_ session: JellyfinAuthenticatedSession) throws {
        let provider = try JellyfinProvider(session: session)
        self.provider = provider
        self.liveTVProvider = try JellyfinLiveTVProvider(session: session)
        state = .connected
    }

    private func prefetch(libraries: [MediaLibrary]) async {
        await withTaskGroup(of: (String, [MediaItem]?).self) { group in
            for library in libraries.prefix(5) where libraryCache[library.id] == nil {
                guard let provider else { continue }
                group.addTask {
                    let value = try? await provider.items(
                        in: library,
                        sort: .addedAtDesc,
                        page: Page(offset: 0, limit: 120)
                    )
                    return (library.id, value?.items)
                }
            }
            for await (id, items) in group {
                if let items { libraryCache[id] = items }
            }
        }
    }

    private func reset(to state: State) {
        provider = nil
        liveTVProvider = nil
        libraries = []
        homeHubs = []
        libraryCache = [:]
        detailCache = [:]
        childrenCache = [:]
        relatedCache = [:]
        quickConnectCode = nil
        self.state = state
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        switch error as? MediaProviderError {
        case .unreachable: return "The Jellyfin server could not be reached."
        case .unauthorized: return "The Jellyfin login is no longer valid."
        case .notFound: return "This item is no longer available."
        case .transcodeRequired: return "This device needs a compatible Jellyfin transcode."
        case .notPlayable: return "Jellyfin did not return a playable stream."
        case .backendSpecific(let message): return message
        case nil: return error.localizedDescription
        }
    }
}
