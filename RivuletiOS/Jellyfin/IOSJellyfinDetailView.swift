// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import WebKit

struct IOSJellyfinDetailView: View {
    let item: MediaItem
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var detail: MediaItemDetail?
    @State private var episodes: [MediaItem] = []
    @State private var related: [MediaItem] = []
    @State private var selectedSeason = 1
    @State private var playback: IOSJellyfinPlaybackContext?
    @State private var isPreparingPlayback = false
    @State private var error: String?
    @State private var isFavorite: Bool
    @State private var isOnWatchlist = false
    @State private var trailerManuallyPaused = false
    @State private var trailerActive = false
    @State private var trailerFinished = false
    @State private var trailerHeroIsVisible = true
    @State private var detailIsVisible = true
    @AppStorage("ios.autoplayTrailers") private var autoplayTrailers = true
    @AppStorage("ios.trailerMuted") private var trailerMuted = true

    init(item: MediaItem) {
        self.item = item
        _isFavorite = State(initialValue: item.userState.isFavorite)
        _selectedSeason = State(initialValue: item.seasonNumber ?? 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        hero(size: geometry.size)
                            .onScrollVisibilityChange(threshold: 0.52) { isVisible in
                                trailerHeroIsVisible = isVisible
                            }
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
        .onAppear { detailIsVisible = true }
        .onDisappear { detailIsVisible = false }
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

            if autoplayTrailers, !trailerFinished, let trailerURL = detail?.trailerURL {
                IOSJellyfinTrailerView(
                    url: trailerURL,
                    isMuted: trailerMuted,
                    shouldPlay: !trailerShouldPause,
                    isActive: $trailerActive,
                    isFinished: $trailerFinished
                )
                .id(trailerURL.absoluteString)
                .frame(width: size.width, height: landscape ? size.width * 0.53 : size.height * 0.57)
                .clipped()
                // YouTube can draw a central play glyph while its iframe is
                // paused even with controls disabled. Reveal the artwork in
                // that state so only Rivulet's own controls remain visible.
                .opacity(trailerActive && !trailerShouldPause ? 1 : 0)
                .transition(.opacity.animation(.easeInOut(duration: 0.65)))
                .allowsHitTesting(false)
            }

            LinearGradient(
                stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.96), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 13) {
                if displayedItem.kind == .episode,
                   let seriesTitle = displayedItem.seriesTitle,
                   !seriesTitle.isEmpty {
                    Text(seriesTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                Text(displayedItem.title)
                    .font(.system(size: landscape ? 44 : 34, weight: .bold, design: .rounded))
                    .lineLimit(2)
                HStack(spacing: 9) {
                    if let coordinate = displayedItem.episodeCoordinate { Text(coordinate) }
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

            if autoplayTrailers, trailerActive, !trailerFinished {
                HStack(spacing: 8) {
                    Button { trailerManuallyPaused.toggle() } label: {
                        Image(systemName: trailerManuallyPaused ? "play.fill" : "pause.fill")
                            .frame(width: 40, height: 40)
                    }
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.14)) }
                    Button { trailerMuted.toggle() } label: {
                        Image(systemName: trailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 40, height: 40)
                    }
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.14)) }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.top, landscape ? 24 : 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(height: landscape ? size.width * 0.53 : size.height * 0.57)
    }

    private var trailerShouldPause: Bool {
        trailerManuallyPaused || !trailerHeroIsVisible || !detailIsVisible || scenePhase != .active
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
            Text("Episodes").font(.title2.bold()).padding(.horizontal, 22)

            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { season in
                            Button {
                                withAnimation(.snappy(duration: 0.26)) { selectedSeason = season }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(seasonLabel(season))
                                    if seasonIsWatched(season) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption.weight(.bold))
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selectedSeason == season ? Color.black : Color.primary)
                            .background(selectedSeason == season ? Color.white : Color.clear, in: Capsule())
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .accessibilityAddTraits(selectedSeason == season ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }

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
    private var seasons: [Int] {
        // Main seasons are the primary path; genuine specials remain available
        // at the end rather than appearing as a misleading first "Season 0".
        Array(Set(episodes.compactMap(\.seasonNumber))).sorted {
            if $0 == 0 { return false }
            if $1 == 0 { return true }
            return $0 < $1
        }
    }
    private var filteredEpisodes: [MediaItem] {
        let matching = episodes.filter { ($0.seasonNumber ?? selectedSeason) == selectedSeason }
        return EpisodePicker.inPlaybackOrder(matching)
    }
    private var playTitle: String {
        let target = displayedItem.kind == .show ? detail?.nextEpisode : displayedItem
        let verb = (target?.isInProgress == true) ? "Resume" : "Play"
        guard let coordinate = target?.episodeCoordinate else { return verb }
        return "\(verb) \(coordinate)"
    }

    private func seasonLabel(_ season: Int) -> String {
        episodes.first(where: { $0.seasonNumber == season })?.seasonDisplayTitle
            ?? (season == 0 ? "Specials" : "Season \(season)")
    }

    private func seasonIsWatched(_ season: Int) -> Bool {
        let seasonEpisodes = episodes.filter { $0.seasonNumber == season }
        return !seasonEpisodes.isEmpty && seasonEpisodes.allSatisfy(\.isWatched)
    }

    private func load() async {
        do {
            async let loadedDetail = jellyfin.detail(for: item)
            async let loadedRelated = jellyfin.related(to: item)
            async let loadedEpisodes = loadEpisodesIfNeeded()
            async let loadedWatchlist = jellyfin.isOnWatchlist(item)
            let result = try await loadedDetail
            detail = result
            related = (try? await loadedRelated) ?? []
            isOnWatchlist = await loadedWatchlist
            if item.kind == .show {
                episodes = await loadedEpisodes
                let ordered = EpisodePicker.inPlaybackOrder(episodes)
                if let season = result.nextEpisode?.seasonNumber
                    ?? ordered.first(where: { $0.userState.viewOffset > 0 || !$0.userState.isPlayed })?.seasonNumber {
                    selectedSeason = season
                } else if let first = seasons.first {
                    selectedSeason = first
                }
            }
            error = nil
        } catch { self.error = IOSJellyfinSession.message(for: error) }
    }

    private func loadEpisodesIfNeeded() async -> [MediaItem] {
        guard item.kind == .show else { return [] }
        return (try? await jellyfin.episodes(of: item)) ?? []
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
            async let resolved = jellyfin.resolve(item)
            async let playbackDetail = try? jellyfin.detail(for: item)
            let stream = try await resolved
            guard let provider = jellyfin.provider else { throw MediaProviderError.unauthorized }
            let orderedEpisodes = EpisodePicker.inPlaybackOrder(episodes)
            let following: [MediaItem]
            if let index = orderedEpisodes.firstIndex(where: { $0.id == item.id }) {
                following = Array(orderedEpisodes.dropFirst(index + 1))
            } else {
                following = []
            }
            playback = IOSJellyfinPlaybackContext(
                item: item,
                stream: stream,
                provider: provider,
                followingEpisodes: following,
                chapters: await playbackDetail?.chapters ?? []
            )
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

/// A deliberately non-interactive trailer stage. YouTube's chrome is removed,
/// playback never loops, and the only controls are the native Liquid Glass
/// pause/mute pair rendered by the detail page.
private struct IOSJellyfinTrailerView: UIViewRepresentable {
    let url: URL
    let isMuted: Bool
    let shouldPlay: Bool
    @Binding var isActive: Bool
    @Binding var isFinished: Bool

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var isActive: Binding<Bool>
        var isFinished: Binding<Bool>

        init(isActive: Binding<Bool>, isFinished: Binding<Bool>) {
            self.isActive = isActive
            self.isFinished = isFinished
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "rivuletTrailer", let state = message.body as? String else { return }
            Task { @MainActor in
                switch state {
                case "playing":
                    self.isActive.wrappedValue = true
                case "ended", "error":
                    self.isActive.wrappedValue = false
                    self.isFinished.wrappedValue = true
                default:
                    break
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive, isFinished: $isFinished)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "rivuletTrailer")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.alpha = 0
        view.loadHTMLString(Self.document(for: url, muted: isMuted), baseURL: Self.documentBaseURL(for: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let muteCommand = isMuted
            ? "if(window.rivuletMute){window.rivuletMute();}"
            : "if(window.rivuletUnmute){window.rivuletUnmute();}"
        let playCommand = shouldPlay
            ? "if(window.rivuletPlay){window.rivuletPlay();}"
            : "if(window.rivuletPause){window.rivuletPause();}"
        view.evaluateJavaScript(muteCommand)
        view.evaluateJavaScript(playCommand)
        view.alpha = isActive && shouldPlay ? 1 : 0
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("if(window.rivuletStop){window.rivuletStop();}")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "rivuletTrailer")
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    private static func document(for url: URL, muted: Bool) -> String {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        if let videoID = youtubeID(from: url) {
            return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
            <meta name="referrer" content="origin"><style>
            *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
            #stage{position:absolute;inset:0;overflow:hidden;background:#000}
            #player{position:absolute;left:0;top:-48px;width:100%;height:calc(100% + 96px)}
            #player iframe{width:100%;height:100%;border:0;pointer-events:none}
            </style></head>
            <body><div id="stage"><div id="player"></div></div><script src="https://www.youtube.com/iframe_api"></script><script>
            function notify(state){try{window.webkit.messageHandlers.rivuletTrailer.postMessage(state)}catch(e){}}
            var player; function onYouTubeIframeAPIReady(){player=new YT.Player('player',{host:'https://www.youtube-nocookie.com',videoId:'\(videoID)',playerVars:{autoplay:1,controls:0,disablekb:1,enablejsapi:1,fs:0,iv_load_policy:3,loop:0,modestbranding:1,playsinline:1,rel:0,origin:'https://flix.isma.sbs',widget_referrer:'https://flix.isma.sbs'},events:{onReady:function(e){\(muted ? "e.target.mute();" : "e.target.unMute();")e.target.playVideo();},onStateChange:function(e){if(e.data===YT.PlayerState.PLAYING){notify('playing')}else if(e.data===YT.PlayerState.ENDED){e.target.stopVideo();notify('ended')}},onError:function(){document.getElementById('player').innerHTML='';notify('error')}}});}
            window.rivuletMute=function(){if(player&&player.mute)player.mute()}; window.rivuletUnmute=function(){if(player&&player.unMute)player.unMute()};
            window.rivuletPause=function(){if(player&&player.pauseVideo)player.pauseVideo()}; window.rivuletPlay=function(){if(player&&player.playVideo)player.playVideo()};
            window.rivuletStop=function(){if(player&&player.stopVideo)player.stopVideo();notify('ended')};
            </script></body></html>
            """
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body,video{margin:0;width:100%;height:100%;overflow:hidden;background:#000;object-fit:cover}video::-webkit-media-controls{display:none!important}</style></head><body>
        <video id="player" src="\(escaped)" autoplay playsinline disablepictureinpicture controlslist="nodownload noplaybackrate nofullscreen" \(muted ? "muted" : "")></video><script>
        function notify(state){try{window.webkit.messageHandlers.rivuletTrailer.postMessage(state)}catch(e){}}
        var player=document.getElementById('player'); window.rivuletMute=function(){player.muted=true}; window.rivuletUnmute=function(){player.muted=false};
        window.rivuletPause=function(){player.pause()}; window.rivuletPlay=function(){player.play()}; window.rivuletStop=function(){player.pause();player.removeAttribute('src');player.load()};
        player.addEventListener('playing',function(){notify('playing')}); player.addEventListener('ended',function(){notify('ended')}); player.addEventListener('error',function(){notify('error')});
        </script></body></html>
        """
    }

    private static func documentBaseURL(for url: URL) -> URL? {
        youtubeID(from: url) == nil ? url.deletingLastPathComponent() : URL(string: "https://flix.isma.sbs/")
    }

    private static func youtubeID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        if host == "youtu.be" { return url.pathComponents.dropFirst().first }
        guard host.contains("youtube.com") else { return nil }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value { return id }
        if let index = url.pathComponents.firstIndex(of: "embed"),
           url.pathComponents.indices.contains(index + 1) { return url.pathComponents[index + 1] }
        return nil
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
    @AppStorage("ios.blurEpisodeSpoilers") private var blurSpoilers = true

    private var hidesSpoilers: Bool {
        blurSpoilers && !episode.isWatched && !episode.isInProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: episode.artwork.thumbnail ?? episode.artwork.backdrop) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { ZStack { Color.white.opacity(0.06); Image(systemName: "play.rectangle") } }
                }
                .frame(width: 290, height: 163).clipped()
                .blur(radius: hidesSpoilers ? 14 : 0)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                if hidesSpoilers {
                    Label("Spoiler hidden", systemImage: "eye.slash.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                Button(action: play) { Image(systemName: "play.fill").frame(width: 42, height: 42) }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: Circle()).padding(12)
                if episode.isWatched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                if let progress = episode.watchProgress { ProgressView(value: progress).tint(.cyan).padding(.horizontal, 7).padding(.bottom, 4) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(episode.title).font(.headline).lineLimit(2).frame(width: 290, alignment: .leading)
            HStack { if let code = episode.episodeCoordinate { Text(code) }; if let duration = episode.durationFormatted { Text(duration) } }
                .font(.caption).foregroundStyle(.secondary)
            if let overview = episode.overview, !overview.isEmpty {
                Text(hidesSpoilers ? "Episode description hidden" : overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(width: 290, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([episode.episodeHierarchyTitle, episode.title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(episode.isInProgress ? "Resumes this episode" : "Plays this episode")
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
                                .frame(width: 164, height: 246).clipShape(RoundedRectangle(cornerRadius: 17))
                                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(width: 164, alignment: .leading)
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
