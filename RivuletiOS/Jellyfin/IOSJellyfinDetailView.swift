// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct IOSJellyfinDetailView: View {
    let item: MediaItem
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @Environment(\.dismiss) private var dismiss
    @State private var detail: MediaItemDetail?
    @State private var episodes: [MediaItem] = []
    @State private var related: [MediaItem] = []
    @State private var selectedSeason = 1
    @State private var playback: IOSJellyfinPlaybackContext?
    @State private var isPreparingPlayback = false
    @State private var error: String?
    @State private var isFavorite: Bool
    @State private var isOnWatchlist = false

    init(item: MediaItem) {
        self.item = item
        _isFavorite = State(initialValue: item.userState.isFavorite)
        _selectedSeason = State(initialValue: max(1, item.seasonNumber ?? 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        hero(size: geometry.size)
                        synopsis
                        metadata
                        if !people.isEmpty { castAndCrew }
                        if !episodes.isEmpty { episodeSection }
                        if !related.isEmpty { IOSJellyfinDetailShelf(title: "You Might Also Like", items: related) }
                    }
                    .padding(.bottom, 36)
                }
            }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
                .padding(.leading, 16)
                .padding(.top, max(8, geometry.safeAreaInsets.top))
                .accessibilityLabel("Back")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
        .task { await load() }
        .fullScreenCover(item: $playback) { IOSJellyfinPlayerView(context: $0) }
        .preferredColorScheme(.dark)
    }

    private func hero(size: CGSize) -> some View {
        let landscape = size.width > size.height
        return ZStack(alignment: .bottomLeading) {
            AsyncImage(url: displayedItem.artwork.backdrop ?? displayedItem.artwork.poster) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() }
                else { LinearGradient(colors: [.gray.opacity(0.25), .black], startPoint: .top, endPoint: .bottom) }
            }
            .frame(width: size.width, height: landscape ? size.width * 0.53 : size.height * 0.57)
            .clipped()

            LinearGradient(
                stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.96), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 13) {
                Text(displayedItem.title)
                    .font(.system(size: landscape ? 44 : 34, weight: .bold, design: .rounded))
                    .lineLimit(2)
                HStack(spacing: 9) {
                    if let year = displayedItem.year { Text(String(year)) }
                    if let rating = detail?.contentRating ?? displayedItem.contentRating { Text(rating).detailPill() }
                    if let duration = displayedItem.durationFormatted { Text(duration) }
                    if let rating = detail?.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
                }
                .font(.subheadline).foregroundStyle(.white.opacity(0.78))
                actionRow
            }
            .padding(.horizontal, landscape ? 48 : 22)
            .padding(.bottom, 24)
        }
        .frame(height: landscape ? size.width * 0.53 : size.height * 0.57)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button { Task { await preparePlayback() } } label: {
                Label(isPreparingPlayback ? "Opening…" : playTitle, systemImage: "play.fill")
                    .font(.headline).padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.white).foregroundStyle(.black)
            .disabled(isPreparingPlayback)

            Button { Task { await toggleWatchlist() } } label: {
                Image(systemName: isOnWatchlist ? "bookmark.fill" : "bookmark")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .accessibilityLabel(isOnWatchlist ? "Remove from watchlist" : "Add to watchlist")

            Button { Task { await toggleFavorite() } } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .red : .white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .accessibilityLabel(isFavorite ? "Remove favorite" : "Favorite")
        }
    }

    @ViewBuilder private var synopsis: some View {
        if let tagline = detail?.tagline, !tagline.isEmpty {
            Text(tagline).font(.title3.italic()).foregroundStyle(.white.opacity(0.82)).padding(.horizontal, 22)
        }
        if let overview = displayedItem.overview, !overview.isEmpty {
            Text(overview)
                .font(.body).lineSpacing(4).foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 22).frame(maxWidth: 900, alignment: .leading)
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.yellow).padding(.horizontal, 22)
        }
    }

    @ViewBuilder private var metadata: some View {
        if let detail, !(detail.genres.isEmpty && detail.studios.isEmpty && detail.directors.isEmpty && detail.writers.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                if !detail.genres.isEmpty { IOSJellyfinMetadataRow(title: "Genres", values: detail.genres) }
                if !detail.directors.isEmpty { IOSJellyfinMetadataRow(title: "Directors", values: detail.directors.map(\.name)) }
                if !detail.writers.isEmpty { IOSJellyfinMetadataRow(title: "Writers", values: detail.writers.map(\.name)) }
                if !detail.studios.isEmpty { IOSJellyfinMetadataRow(title: "Studios", values: detail.studios) }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1)) }
            .padding(.horizontal, 22)
        }
    }

    private var castAndCrew: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Cast & Crew").font(.title2.bold()).padding(.horizontal, 22)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(people) { person in
                        VStack(spacing: 8) {
                            AsyncImage(url: person.imageURL) { phase in
                                if case .success(let image) = phase { image.resizable().scaledToFill() }
                                else { ZStack { Color.white.opacity(0.07); Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary) } }
                            }
                            .frame(width: 116, height: 116).clipShape(Circle())
                            .overlay { Circle().stroke(.white.opacity(0.13)) }
                            Text(person.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let role = person.role { Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        .frame(width: 132)
                    }
                }
                .padding(.horizontal, 22)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Episodes").font(.title2.bold())
                Spacer()
                if seasons.count > 1 {
                    Picker("Season", selection: $selectedSeason) {
                        ForEach(seasons, id: \.self) { Text("Season \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(.horizontal, 22)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(filteredEpisodes) { episode in
                        IOSJellyfinEpisodeCard(episode: episode) {
                            Task { await preparePlayback(item: episode) }
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var displayedItem: MediaItem { detail?.item ?? item }
    private var people: [MediaPerson] {
        guard let detail else { return [] }
        var seen = Set<String>()
        return (detail.cast + detail.directors + detail.writers).filter { seen.insert($0.id).inserted }
    }
    private var seasons: [Int] { Array(Set(episodes.compactMap(\.seasonNumber))).sorted() }
    private var filteredEpisodes: [MediaItem] {
        let matching = episodes.filter { ($0.seasonNumber ?? selectedSeason) == selectedSeason }
        return EpisodePicker.inPlaybackOrder(matching)
    }
    private var playTitle: String { displayedItem.userState.viewOffset > 0 ? "Resume" : "Play" }

    private func load() async {
        do {
            async let loadedDetail = jellyfin.detail(for: item)
            async let loadedRelated = jellyfin.related(to: item)
            let result = try await loadedDetail
            detail = result
            related = (try? await loadedRelated) ?? []
            isOnWatchlist = await jellyfin.isOnWatchlist(item)
            if item.kind == .show {
                episodes = (try? await jellyfin.episodes(of: item)) ?? []
                if let season = episodes.first(where: { $0.userState.viewOffset > 0 || !$0.userState.isPlayed })?.seasonNumber {
                    selectedSeason = season
                } else if let first = seasons.first {
                    selectedSeason = first
                }
            }
            error = nil
        } catch { self.error = IOSJellyfinSession.message(for: error) }
    }

    private func preparePlayback() async {
        guard let provider = jellyfin.provider else { return }
        let target = await EpisodePicker.resolvePlayTarget(for: displayedItem, provider: provider) ?? displayedItem
        await preparePlayback(item: target)
    }

    private func preparePlayback(item: MediaItem) async {
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        do {
            let stream = try await jellyfin.resolve(item)
            guard let provider = jellyfin.provider else { throw MediaProviderError.unauthorized }
            playback = IOSJellyfinPlaybackContext(item: item, stream: stream, provider: provider)
        } catch { self.error = IOSJellyfinSession.message(for: error) }
    }

    private func toggleFavorite() async {
        let next = !isFavorite
        do { try await jellyfin.setFavorite(displayedItem, enabled: next); withAnimation { isFavorite = next } }
        catch { self.error = IOSJellyfinSession.message(for: error) }
    }

    private func toggleWatchlist() async {
        let next = !isOnWatchlist
        do { try await jellyfin.setWatchlist(displayedItem, enabled: next); withAnimation { isOnWatchlist = next } }
        catch { self.error = IOSJellyfinSession.message(for: error) }
    }
}

private struct IOSJellyfinMetadataRow: View {
    let title: String
    let values: [String]
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(values.joined(separator: " · ")).font(.subheadline).foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct IOSJellyfinEpisodeCard: View {
    let episode: MediaItem
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: episode.artwork.thumbnail ?? episode.artwork.backdrop) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { ZStack { Color.white.opacity(0.06); Image(systemName: "play.rectangle") } }
                }
                .frame(width: 290, height: 163).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                Button(action: play) { Image(systemName: "play.fill").frame(width: 42, height: 42) }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle()).padding(12)
                if episode.isWatched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                if let progress = episode.watchProgress { ProgressView(value: progress).tint(.cyan).padding(.horizontal, 7).padding(.bottom, 4) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(episode.title).font(.headline).lineLimit(2).frame(width: 290, alignment: .leading)
            HStack { if let code = episode.episodeString { Text(code) }; if let duration = episode.durationFormatted { Text(duration) } }
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct IOSJellyfinDetailShelf: View {
    let title: String
    let items: [MediaItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).padding(.horizontal, 22)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            VStack(alignment: .leading, spacing: 7) {
                                AsyncImage(url: item.artwork.poster ?? item.artwork.thumbnail) { phase in
                                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                                    else { Color.white.opacity(0.06) }
                                }
                                .frame(width: 138, height: 207).clipShape(RoundedRectangle(cornerRadius: 15))
                                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(width: 138, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private extension View {
    func detailPill() -> some View {
        padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.12), in: Capsule())
    }
}
