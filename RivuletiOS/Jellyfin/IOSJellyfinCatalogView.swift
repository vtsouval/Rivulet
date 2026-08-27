// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct IOSJellyfinCatalogView: View {
    let kind: JellyfinCatalogKind

    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var filter: JellyfinCatalogFilter = .all
    @State private var genre: JellyfinCatalogGenre?
    @State private var sort: SortOption = .addedAtDesc
    @State private var items: [MediaItem] = []
    @State private var genres: [JellyfinCatalogGenre] = []
    @State private var total = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var error: String?

    private var request: JellyfinCatalogQuery {
        JellyfinCatalogQuery(kind: kind, genre: genre?.name, filter: filter, sort: sort)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 22) {
                    filterBar
                    if filter == .all, genre == nil, !genres.isEmpty {
                        IOSJellyfinCatalogGenreShelves(kind: kind, genres: genres)
                    }
                    if !items.isEmpty {
                        HStack {
                            Text(gridTitle).font(.title2.bold())
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                    if items.isEmpty, isLoading {
                        skeleton
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 16)],
                            spacing: 22
                        ) {
                            ForEach(items) { item in
                                NavigationLink(value: item) {
                                    IOSJellyfinPosterCard(item: item, width: nil)
                                }
                                .buttonStyle(.plain)
                                .onAppear { prefetchIfNeeded(item) }
                            }
                        }
                        .padding(.horizontal)
                    }

                    if isLoadingMore {
                        ProgressView().controlSize(.small).padding(.vertical, 22)
                    }
                }
                .padding(.bottom, 32)
            }
            .overlay {
                if !isLoading, items.isEmpty {
                    ContentUnavailableView(
                        error == nil ? "Nothing here yet" : "Couldn’t load \(kind.title.lowercased())",
                        systemImage: error == nil ? kind.symbolName : "exclamationmark.triangle",
                        description: Text(error ?? "Try another filter or genre.")
                    )
                }
            }
            .navigationTitle(kind.title)
            .toolbar { IOSJellyfinAccountToolbar() }
            .navigationDestination(for: MediaItem.self) { IOSJellyfinDetailView(item: $0) }
            .task(id: request) { await load(force: false) }
            .task {
                guard genres.isEmpty else { return }
                genres = (try? await jellyfin.genres(for: kind)) ?? []
            }
            .refreshable { await load(force: true) }
        }
    }

    private var gridTitle: String {
        if let genre { return genre.name }
        if filter != .all { return filter.title }
        return sort == .addedAtDesc ? "Recently Added" : sort.title
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(JellyfinCatalogFilter.allCases) { option in
                        Button {
                            withAnimation(.snappy(duration: 0.28)) { filter = option }
                        } label: {
                            Label(option.title, systemImage: option.symbolName)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(filter == option ? Color.black : Color.primary)
                        .background(filter == option ? Color.white : Color.clear, in: Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)

            Text("Genres")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    genreButton(title: "All", value: nil)
                    ForEach(genres) { value in
                        genreButton(title: value.name, value: value)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 3)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Menu {
                    Button("Recently Added") { sort = .addedAtDesc }
                    Button("Title") { sort = .titleAsc }
                    Button("Release Date") { sort = .releaseDateDesc }
                    Button("Rating") { sort = .ratingDesc }
                } label: {
                    Label(sort.title, systemImage: "arrow.up.arrow.down")
                }
                Spacer()
                if total > 0 { Text("\(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal)
            .padding(.top, 2)
        }
    }

    private func genreButton(title: String, value: JellyfinCatalogGenre?) -> some View {
        let selected = genre?.id == value?.id
        return Button {
            withAnimation(.snappy(duration: 0.26)) { genre = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.black : Color.primary)
        .background(selected ? Color.white : Color.clear, in: Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 16)], spacing: 20) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.07)).aspectRatio(2 / 3, contentMode: .fit)
            }
        }
        .padding(.horizontal).redacted(reason: .placeholder)
    }

    private func load(force: Bool) async {
        isLoading = items.isEmpty
        defer { isLoading = false }
        do {
            let page = try await jellyfin.catalog(request, force: force)
            guard !Task.isCancelled else { return }
            items = page.items
            total = page.total
            hasMore = page.hasMore
            error = nil
        } catch is CancellationError { }
        catch { self.error = IOSJellyfinSession.message(for: error) }
    }

    private func prefetchIfNeeded(_ item: MediaItem) {
        guard hasMore, !isLoadingMore,
              let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 10 else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            do {
                let page = try await jellyfin.catalog(request, loadMore: true)
                items = page.items
                total = page.total
                hasMore = page.hasMore
                error = nil
            } catch is CancellationError { }
            catch { self.error = IOSJellyfinSession.message(for: error) }
        }
    }
}

/// Library-specific, paged genre rails. Home-only material such as Continue
/// Watching and Director's Picks never enters this surface.
private struct IOSJellyfinCatalogGenreShelves: View {
    let kind: JellyfinCatalogKind
    let genres: [JellyfinCatalogGenre]

    private var visibleGenres: [JellyfinCatalogGenre] {
        let preferred = [
            "Action", "Drama", "Comedy", "Crime", "Documentary",
            "Science Fiction", "Thriller", "Family"
        ]
        let ordered = preferred.compactMap { name in
            genres.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        let used = Set(ordered.map(\.id))
        return Array((ordered + genres.filter { !used.contains($0.id) }).prefix(8))
    }

    var body: some View {
        ForEach(visibleGenres) { genre in
            IOSJellyfinPagedCatalogShelf(
                title: genre.name,
                request: JellyfinCatalogQuery(
                    kind: kind,
                    genre: genre.name,
                    sort: .ratingDesc
                )
            )
        }
    }
}

struct IOSJellyfinAccountToolbar: ToolbarContent {
    @State private var showsSettings = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showsSettings = true } label: {
                Image(systemName: "person.crop.circle.fill")
            }
            .accessibilityLabel("Account and settings")
            .sheet(isPresented: $showsSettings) { IOSJellyfinSettingsView() }
        }
    }
}

private extension JellyfinCatalogKind {
    var symbolName: String { self == .movies ? "film.stack" : "tv" }
}

private extension SortOption {
    var title: String {
        switch self {
        case .titleAsc: "Title"
        case .titleDesc: "Title (Z–A)"
        case .releaseDateDesc: "Release Date"
        case .addedAtDesc: "Recently Added"
        case .ratingDesc: "Rating"
        }
    }
}
