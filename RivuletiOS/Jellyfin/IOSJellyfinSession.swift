// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation

/// Main-actor adapter between the shared Jellyfin provider and SwiftUI.
/// Passwords never leave the sign-in task; only Jellyfin's revocable token is
/// persisted by `JellyfinSessionStore` in Keychain.
@MainActor
final class IOSJellyfinSession: ObservableObject {
    private struct SearchCacheEntry {
        let storedAt: Date
        let items: [MediaItem]
    }

    struct CatalogPage: Sendable {
        let items: [MediaItem]
        let total: Int
        let hasMore: Bool
    }

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
    @Published private(set) var quickConnectPayloadURL: URL?

    private(set) var provider: JellyfinProvider?
    private(set) var liveTVProvider: JellyfinLiveTVProvider?
    private var libraryCache: [String: [MediaItem]] = [:]
    private var detailCache: [MediaItemRef: MediaItemDetail] = [:]
    private var childrenCache: [MediaItemRef: [MediaItem]] = [:]
    private var relatedCache: [MediaItemRef: [MediaItem]] = [:]
    private var catalogCache: [JellyfinCatalogQuery: PagedResult<MediaItem>] = [:]
    private var genreCache: [JellyfinCatalogKind: [JellyfinCatalogGenre]] = [:]
    private var catalogTasks: [JellyfinCatalogQuery: Task<PagedResult<MediaItem>, Error>] = [:]
    private var searchCache: [String: SearchCacheEntry] = [:]
    private var refreshTask: Task<Void, Never>?
    private var continueWatchingRefreshTask: Task<Void, Never>?
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
            restoreSnapshot(for: session)
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
            refreshAfterAuthentication()
        } catch {
            state = .failed(Self.message(for: error))
            throw error
        }
    }

    func quickConnect(server: String) async throws {
        state = .connecting
        quickConnectCode = nil
        quickConnectPayloadURL = nil
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
            quickConnectPayloadURL = try JellyfinQuickConnectPayload(
                serverURL: transport.baseURL,
                code: started.code
            ).url
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
            quickConnectPayloadURL = nil
            try attach(session)
            refreshAfterAuthentication()
        } catch is CancellationError {
            quickConnectCode = nil
            quickConnectPayloadURL = nil
            state = .signedOut
            throw CancellationError()
        } catch {
            quickConnectCode = nil
            quickConnectPayloadURL = nil
            state = .failed(Self.message(for: error))
            throw error
        }
    }

    /// Signs this installation in by consuming Bonfire's five-minute,
    /// single-use pairing link. Only the resulting revocable Jellyfin token is
    /// persisted, using the same Keychain-backed path as password, passkey and
    /// standard Quick Connect authentication.
    func claimDevicePairing(_ payload: JellyfinDevicePairingPayload) async throws {
        state = .connecting
        quickConnectCode = nil
        quickConnectPayloadURL = nil
        do {
            let transport = try JellyfinTransport(
                serverURL: payload.serverURL,
                clientIdentity: JellyfinSessionStore.clientIdentity()
            )
            let auth = JellyfinAuthClient(transport: transport)
            _ = try await auth.publicSystemInfo()
            let session = try await auth.authenticateWithDevicePairing(payload: payload)
            try await JellyfinSessionStore.shared.persist(session)
            UserDefaults.standard.set(session.serverURL.absoluteString, forKey: "jellyfin.lastServerURL")
            try attach(session)
            refreshAfterAuthentication()
        } catch is CancellationError {
            state = .signedOut
            throw CancellationError()
        } catch {
            state = .failed(Self.message(for: error))
            throw error
        }
    }

    /// Lets an already signed-in iPhone authorize a television or another
    /// client. The QR server must exactly match the active authenticated
    /// server, preventing a scan from sending this token to another origin.
    func authorizeQuickConnect(payload: JellyfinQuickConnectPayload) async throws {
        guard let provider else { throw MediaProviderError.unauthorized }
        guard payload.belongs(to: provider.session) else {
            throw JellyfinAPIError.forbidden(
                message: "This Quick Connect request belongs to another Jellyfin server."
            )
        }
        let authorized = try await JellyfinAuthClient(transport: provider.transport).authorizeQuickConnect(
            code: payload.code,
            userID: provider.session.user.id,
            accessToken: provider.session.accessToken
        )
        guard authorized else {
            throw JellyfinAPIError.unauthorized(message: "The Quick Connect code expired or was not accepted.")
        }
    }

    func authorizeQuickConnect(code: String) async throws {
        guard let session = provider?.session else { throw MediaProviderError.unauthorized }
        let payload = try JellyfinQuickConnectPayload(serverURL: session.serverURL, code: code)
        try await authorizeQuickConnect(payload: payload)
    }

    func authorizeQuickConnect(url: URL) async throws {
        try await authorizeQuickConnect(payload: JellyfinQuickConnectPayload(url: url))
    }

    func passkeySignIn(server: String) async throws {
        state = .connecting
        quickConnectCode = nil
        quickConnectPayloadURL = nil
        do {
            let transport = try JellyfinTransport(
                serverURL: server,
                clientIdentity: JellyfinSessionStore.clientIdentity()
            )
            let client = JellyfinPasskeyClient(transport: transport)
            let status = try await client.status()
            guard status.enabled, let reportedOrigin = status.origin else {
                throw JellyfinAPIError.forbidden(
                    message: "Passkey sign-in is not configured on this Jellyfin server."
                )
            }
            let originURL = try client.validatedOrigin(reportedOrigin)
            guard let relyingPartyID = originURL.host else {
                throw JellyfinAPIError.invalidServerURL
            }
            let origin = originURL.absoluteString
            let ceremony = try await client.beginAuthentication(origin: origin)
            let credential = try await IOSJellyfinPasskeyCoordinator.shared.assertion(
                options: ceremony.publicKey,
                fallbackRelyingPartyID: relyingPartyID
            )
            let session = try await client.completeAuthentication(
                transactionID: ceremony.transactionId,
                credential: credential,
                origin: origin
            )
            try await JellyfinSessionStore.shared.persist(session)
            UserDefaults.standard.set(session.serverURL.absoluteString, forKey: "jellyfin.lastServerURL")
            try attach(session)
            refreshAfterAuthentication()
        } catch {
            state = .failed(Self.message(for: error))
            throw error
        }
    }

    func passkeyStatus() async throws -> JellyfinPasskeyStatus {
        let context = try passkeyContext()
        return try await context.client.status(userID: context.session.user.id)
    }

    func passkeyRecords() async throws -> [JellyfinPasskeyRecord] {
        let context = try passkeyContext()
        return try await context.client.records(accessToken: context.session.accessToken)
    }

    func enrollPasskey(currentPassword: String, name: String) async throws {
        let context = try passkeyContext()
        let status = try await context.client.status(userID: context.session.user.id)
        guard status.enabled, let reportedOrigin = status.origin else {
            throw JellyfinAPIError.forbidden(
                message: "Passkeys are not configured on this Jellyfin server."
            )
        }
        let originURL = try context.client.validatedOrigin(reportedOrigin)
        guard let relyingPartyID = originURL.host else {
            throw JellyfinAPIError.invalidServerURL
        }
        let origin = originURL.absoluteString
        let ceremony = try await context.client.beginRegistration(
            currentPassword: currentPassword,
            name: name,
            origin: origin,
            accessToken: context.session.accessToken
        )
        let credential = try await IOSJellyfinPasskeyCoordinator.shared.registration(
            options: ceremony.publicKey,
            fallbackRelyingPartyID: relyingPartyID
        )
        try await context.client.completeRegistration(
            transactionID: ceremony.transactionId,
            credential: credential,
            origin: origin,
            accessToken: context.session.accessToken
        )
    }

    func removePasskey(_ record: JellyfinPasskeyRecord) async throws {
        let context = try passkeyContext()
        try await context.client.remove(
            recordID: record.id,
            accessToken: context.session.accessToken
        )
    }

    func signOut() async {
        await JellyfinSessionStore.shared.signOut()
        reset(to: .signedOut)
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Refreshes the one home rail whose state can change on another device.
    /// Jellyfin owns the progress and resume point; this client merely paints
    /// the current authenticated user's `/Items/Resume` response.
    func refreshContinueWatching() async {
        guard provider != nil else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        if let continueWatchingRefreshTask {
            await continueWatchingRefreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performContinueWatchingRefresh()
        }
        continueWatchingRefreshTask = task
        await task.value
        continueWatchingRefreshTask = nil
    }

    private func performContinueWatchingRefresh() async {
        guard let provider,
              let fetched = try? await provider.continueWatching(limit: 24) else { return }
        let showAnime = (UserDefaults.standard.object(forKey: "ios.showAnime") as? Bool) ?? true
        let items = showAnime ? fetched : fetched.filter { !$0.isAnime }
        let continueHub = items.isEmpty ? nil : MediaHub(
            id: "\(provider.id):continue",
            providerID: provider.id,
            title: "Continue Watching",
            style: .shelf,
            items: items
        )
        var updated = homeHubs.filter {
            $0.title != "Continue Watching" && $0.title != "Next Up"
        }
        if let continueHub { updated.insert(continueHub, at: 0) }
        homeHubs = updated
        saveSnapshot()
    }

    private func performRefresh() async {
        guard let provider else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let fetchedLibraries = provider.libraries()
            async let fetchedHubs = provider.hubs()
            async let fetchedPreferences = provider.synchronizedPreferences()
            let (libraries, hubs, preferences) = try await (
                fetchedLibraries, fetchedHubs, fetchedPreferences
            )
            apply(preferences)
            self.libraries = libraries
            self.homeHubs = Self.sanitizedHomeHubs(hubs)
            state = .connected
            saveSnapshot()

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

    /// Loads one page and merges it with the existing catalog without
    /// duplicating cards. The matching in-flight task is shared by fast repeat
    /// taps and SwiftUI re-rendering, so one gesture never fans out into
    /// multiple identical Jellyfin requests.
    func catalog(
        _ request: JellyfinCatalogQuery,
        loadMore: Bool = false,
        force: Bool = false,
        pageSize: Int = 48
    ) async throws -> CatalogPage {
        guard let provider else { throw MediaProviderError.unauthorized }
        let existing = force ? nil : catalogCache[request]
        if !loadMore, let existing {
            return CatalogPage(items: existing.items, total: existing.total, hasMore: existing.nextPage != nil)
        }
        if loadMore, existing?.nextPage == nil, existing != nil {
            return CatalogPage(items: existing!.items, total: existing!.total, hasMore: false)
        }
        if let task = catalogTasks[request] {
            let result = try await task.value
            return CatalogPage(items: result.items, total: result.total, hasMore: result.nextPage != nil)
        }

        let page = loadMore ? (existing?.nextPage ?? Page(offset: existing?.items.count ?? 0, limit: pageSize))
            : Page(offset: 0, limit: pageSize)
        let task = Task { try await provider.catalog(request, page: page) }
        catalogTasks[request] = task
        defer { catalogTasks[request] = nil }
        let fetched = try await task.value
        let merged: PagedResult<MediaItem>
        if loadMore, let existing {
            var seen = Set(existing.items.map(\.id))
            let newItems = fetched.items.filter { seen.insert($0.id).inserted }
            merged = PagedResult(
                items: existing.items + newItems,
                total: max(existing.total, fetched.total),
                nextPage: fetched.nextPage
            )
        } else {
            merged = fetched
        }
        catalogCache[request] = merged
        saveSnapshot()
        return CatalogPage(items: merged.items, total: merged.total, hasMore: merged.nextPage != nil)
    }

    func genres(for kind: JellyfinCatalogKind, force: Bool = false) async throws -> [JellyfinCatalogGenre] {
        if !force, let cached = genreCache[kind] { return cached }
        guard let provider else { throw MediaProviderError.unauthorized }
        let values = JellyfinCatalogGenre.standardOnly(try await provider.catalogGenres(kind: kind))
        genreCache[kind] = values
        return values
    }

    func clearCachedData() {
        guard let session = provider?.session else { return }
        IOSJellyfinSnapshotCache.shared.remove(server: session.serverURL, userID: session.user.id)
        libraryCache.removeAll()
        detailCache.removeAll()
        childrenCache.removeAll()
        relatedCache.removeAll()
        catalogCache.removeAll()
        genreCache.removeAll()
    }

    var cachedDataSize: String {
        ByteCountFormatter.string(
            fromByteCount: IOSJellyfinSnapshotCache.shared.totalBytes(),
            countStyle: .file
        )
    }

    func items(in library: MediaLibrary, force: Bool = false) async throws -> [MediaItem] {
        if !force, let cached = libraryCache[library.id] { return cached }
        guard let provider else { throw MediaProviderError.unauthorized }
        let result = try await provider.items(
            in: library,
            sort: .addedAtDesc,
            page: Page(offset: 0, limit: 72)
        )
        libraryCache[library.id] = result.items
        return result.items
    }

    func search(_ query: String) async throws -> [MediaItem] {
        guard let provider else { throw MediaProviderError.unauthorized }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let cached = searchCache[key], Date().timeIntervalSince(cached.storedAt) < 300 {
            return visibleSearchItems(cached.items)
        }

        let items = try await provider.search(term)
        try Task.checkCancellation()
        searchCache[key] = SearchCacheEntry(storedAt: Date(), items: items)
        if searchCache.count > 20,
           let oldest = searchCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            searchCache.removeValue(forKey: oldest)
        }
        return visibleSearchItems(items)
    }

    private func visibleSearchItems(_ items: [MediaItem]) -> [MediaItem] {
        let showAnime = (UserDefaults.standard.object(forKey: "ios.showAnime") as? Bool) ?? true
        return showAnime ? items : items.filter { !$0.isAnime }
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

    func updateContentPreferences(_ patch: JellyfinContentPreferencesPatch) async throws {
        guard let provider else { throw MediaProviderError.unauthorized }
        apply(try await provider.updateContentPreferences(patch))
        // Discovery shelves may include Anime or trailer-derived presentation;
        // rebuild them immediately after a cross-client preference change.
        homeHubs = Self.sanitizedHomeHubs(try await provider.hubs())
        saveSnapshot()
    }

    func updateMediaPreferences(_ patch: JellyfinMediaPreferencesPatch) async throws {
        guard let provider else { throw MediaProviderError.unauthorized }
        apply(try await provider.updateMediaPreferences(patch))
    }

    private func apply(_ preferences: JellyfinSynchronizedPreferences) {
        JellyfinPlaybackPreferences.applyToLocalDefaults(preferences)
        let defaults = UserDefaults.standard
        let suffix = userName ?? "default"
        if let code = preferences.defaultLiveTVCountry,
           let country = Self.liveTVCountryName(for: code) {
            defaults.set(country, forKey: "ios.liveTV.country.\(suffix)")
        }
        if let code = preferences.preferredSportsCountry,
           let country = Self.liveTVCountryName(for: code) {
            defaults.set(country, forKey: "ios.liveTV.sportsCountry.\(suffix)")
        }
    }

    private static func liveTVCountryName(for code: String) -> String? {
        switch code.uppercased() {
        case "ALL": return "All"
        case "GR": return "Greece"
        case "NL": return "Netherlands"
        case "AU": return "Australia"
        case "KR": return "Korea"
        default: return nil
        }
    }

    private func attach(_ session: JellyfinAuthenticatedSession) throws {
        let provider = try JellyfinProvider(session: session)
        self.provider = provider
        self.liveTVProvider = try JellyfinLiveTVProvider(session: session)
        state = .connected
    }

    private func restoreSnapshot(for session: JellyfinAuthenticatedSession) {
        guard let snapshot = IOSJellyfinSnapshotCache.shared.load(
            server: session.serverURL,
            userID: session.user.id
        ) else { return }
        libraries = snapshot.libraries
        homeHubs = Self.sanitizedHomeHubs(snapshot.homeHubs)
        for (key, items) in snapshot.catalogs {
            guard let request = Self.catalogRequest(from: key) else { continue }
            catalogCache[request] = PagedResult(
                items: items,
                total: items.count,
                nextPage: Page(offset: items.count, limit: 48)
            )
        }
    }

    private func saveSnapshot() {
        guard let session = provider?.session else { return }
        var catalogs: [String: [MediaItem]] = [:]
        // Keep visible genre and studio rails warm across launches. The snapshot
        // remains metadata-only and bounded per rail, while authentication stays
        // in Keychain.
        for (request, page) in catalogCache where request.filter == .all {
            catalogs[Self.catalogKey(for: request)] = Array(page.items.prefix(72))
        }
        IOSJellyfinSnapshotCache.shared.save(
            IOSJellyfinSnapshot(
                version: IOSJellyfinSnapshot.currentVersion,
                updatedAt: Date(),
                libraries: libraries,
                homeHubs: homeHubs,
                catalogs: catalogs
            ),
            server: session.serverURL,
            userID: session.user.id
        )
    }

    private static func sanitizedHomeHubs(_ hubs: [MediaHub]) -> [MediaHub] {
        hubs.filter { $0.title != "Next Up" }
    }

    private static func catalogKey(for request: JellyfinCatalogQuery) -> String {
        [
            request.kind.rawValue,
            request.libraryID ?? "",
            request.genre ?? "",
            request.studios.joined(separator: ","),
            request.filter.rawValue,
            request.sort.cacheKey
        ].joined(separator: "|")
    }

    private static func catalogRequest(from key: String) -> JellyfinCatalogQuery? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        // Read the pre-1.7 three-part key as well as the richer current key so
        // an update never throws away a useful warm catalog snapshot.
        if parts.count == 3,
           let kind = JellyfinCatalogKind(rawValue: parts[0]),
           let sort = SortOption(cacheKey: parts[2]) {
            return JellyfinCatalogQuery(
                kind: kind,
                libraryID: parts[1].isEmpty ? nil : parts[1],
                sort: sort
            )
        }
        guard parts.count == 6,
              let kind = JellyfinCatalogKind(rawValue: parts[0]),
              let filter = JellyfinCatalogFilter(rawValue: parts[4]),
              let sort = SortOption(cacheKey: parts[5]) else { return nil }
        return JellyfinCatalogQuery(
            kind: kind,
            libraryID: parts[1].isEmpty ? nil : parts[1],
            genre: parts[2].isEmpty ? nil : parts[2],
            studios: parts[3].isEmpty ? [] : parts[3].split(separator: ",").map(String.init),
            filter: filter,
            sort: sort
        )
    }

    /// Hand control to the signed-in UI immediately and hydrate home data in
    /// an independent task. This prevents the sign-in view's disappearance
    /// from cancelling the refresh that follows a successful login.
    private func refreshAfterAuthentication() {
        Task(priority: .userInitiated) { [weak self] in
            await self?.refresh()
        }
    }

    private func passkeyContext() throws -> (
        client: JellyfinPasskeyClient,
        session: JellyfinAuthenticatedSession
    ) {
        guard let session = JellyfinSessionStore.shared.currentSession else {
            throw MediaProviderError.unauthorized
        }
        let transport = try JellyfinTransport(
            serverURL: session.serverURL,
            clientIdentity: session.clientIdentity
        )
        return (JellyfinPasskeyClient(transport: transport), session)
    }

    private func prefetch(libraries: [MediaLibrary]) async {
        guard let provider else { return }
        async let movies = try? catalog(JellyfinCatalogQuery(kind: .movies), pageSize: 48)
        async let shows = try? catalog(JellyfinCatalogQuery(kind: .shows), pageSize: 48)
        _ = await (movies, shows)
        let candidates = libraries.filter {
            $0.kind == .movies || $0.kind == .shows || $0.kind == .mixed
        }.prefix(2)

        // Warm only the two primary media libraries and do so sequentially.
        // Concurrent recursive scans of Live TV, playlists and collections can
        // monopolize a remote Jellyfin server and delay the foreground tap.
        for library in candidates where libraryCache[library.id] == nil {
            guard !Task.isCancelled else { return }
            let value = try? await provider.items(
                in: library,
                sort: .addedAtDesc,
                page: Page(offset: 0, limit: 72)
            )
            if let items = value?.items { libraryCache[library.id] = items }
            await Task.yield()
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
        catalogCache = [:]
        genreCache = [:]
        catalogTasks.values.forEach { $0.cancel() }
        catalogTasks = [:]
        searchCache = [:]
        continueWatchingRefreshTask?.cancel()
        continueWatchingRefreshTask = nil
        quickConnectCode = nil
        quickConnectPayloadURL = nil
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

private extension SortOption {
    var cacheKey: String {
        switch self {
        case .titleAsc: "titleAsc"
        case .titleDesc: "titleDesc"
        case .releaseDateDesc: "releaseDateDesc"
        case .addedAtDesc: "addedAtDesc"
        case .ratingDesc: "ratingDesc"
        }
    }

    init?(cacheKey: String) {
        switch cacheKey {
        case "titleAsc": self = .titleAsc
        case "titleDesc": self = .titleDesc
        case "releaseDateDesc": self = .releaseDateDesc
        case "addedAtDesc": self = .addedAtDesc
        case "ratingDesc": self = .ratingDesc
        default: return nil
        }
    }
}
