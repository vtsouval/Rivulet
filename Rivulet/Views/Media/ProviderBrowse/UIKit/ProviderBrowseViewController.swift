// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import os.log

private let providerBrowseLog = Logger(subsystem: "com.rivulet.app", category: "ProviderBrowse")

/// Native UIKit home/library/search surface for a `MediaProvider`.
///
/// Plex keeps its mature `PlexHomeViewController`. This controller is the
/// provider-neutral path used by Jellyfin: it consumes only `MediaProvider`
/// models and reuses the same TVUIKit poster, shelf, detail, focus, image-cache,
/// and player components as the Plex surface.
@MainActor
final class ProviderBrowseViewController: UIViewController {
    enum Mode: Hashable {
        case home
        case library(MediaLibrary)
        case search
    }

    private enum PresentationKind {
        case shelf(continueWatching: Bool)
        case grid
    }

    private struct Section {
        let id: String
        let title: String
        let presentation: PresentationKind
        var items: [MediaItem]
        var total: Int?
        var nextPage: Page?
    }

    let providerID: String
    let mode: Mode

    /// Search container uses this to keep the root shell's tab interaction
    /// blocked while a provider detail is covering the results page.
    var onNestedChange: ((Bool) -> Void)?

    private var provider: (any MediaProvider)? {
        MediaProviderRegistry.shared.provider(for: providerID)
    }

    private var sections: [Section] = []
    private var collectionView: UICollectionView!
    private let statusView = ProviderBrowseStatusView()
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var imageWarmTask: Task<Void, Never>?
    private var loadingNextPage = false
    private var lastSearchQuery = ""
    private var pendingFocus: IndexPath?
    private var refreshObserver: NSObjectProtocol?

    init(providerID: String, mode: Mode) {
        self.providerID = providerID
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        searchTask?.cancel()
        imageWarmTask?.cancel()
        if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCollectionView()
        configureStatusView()

        refreshObserver = NotificationCenter.default.addObserver(
            forName: .plexDataNeedsRefresh,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterPlayback() }
        }

        switch mode {
        case .home, .library:
            loadInitialContent()
        case .search:
            showSearchPrompt()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if presentedViewController == nil { reportNested(false) }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocus,
           let cell = collectionView.cellForItem(at: pendingFocus) {
            self.pendingFocus = nil
            return [cell]
        }
        if statusView.isHidden { return [collectionView] }
        return super.preferredFocusEnvironments
    }

    // MARK: - Public search input

    func updateSearchQuery(_ rawQuery: String) {
        guard case .search = mode else { return }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != lastSearchQuery else { return }
        lastSearchQuery = query
        searchTask?.cancel()

        guard !query.isEmpty else {
            sections = []
            collectionView.reloadData()
            showSearchPrompt()
            return
        }

        statusView.apply(.loading)
        collectionView.isHidden = true
        searchTask = Task { [weak self] in
            // Debounce keyboard edits, but make an already-cached query paint
            // without waiting for the debounce window.
            guard let self else { return }
            if let cached = await ProviderBrowseCache.shared.searchResults(providerID: providerID, query: query) {
                guard !Task.isCancelled, query == lastSearchQuery else { return }
                applySearch(cached, query: query)
                return
            }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, query == lastSearchQuery else { return }
            guard let provider else {
                showError("The selected media server is no longer available.")
                return
            }
            do {
                let results = try await provider.search(query)
                guard !Task.isCancelled, query == lastSearchQuery else { return }
                await ProviderBrowseCache.shared.storeSearchResults(results, providerID: providerID, query: query)
                applySearch(results, query: query)
            } catch {
                guard !Task.isCancelled, query == lastSearchQuery else { return }
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Setup

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = mode == .search ? 24 : 108
        collectionView.verticalScrollIndicatorInsets.top = collectionView.contentInset.top
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.register(
            HubHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: HubHeaderView.reuseID
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureStatusView() {
        statusView.onRetry = { [weak self] in self?.retry() }
        view.addSubview(statusView)
        NSLayoutConstraint.activate([
            statusView.topAnchor.constraint(equalTo: view.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            guard let self, sectionIndex < self.sections.count else { return nil }
            let section = self.sections[sectionIndex]
            switch section.presentation {
            case .shelf(let isContinueWatching):
                let tileHeight = isContinueWatching ? MediaRowMetrics.cwHeight : MediaRowMetrics.posterHeight
                let height = ShelfRowCell.headerHeight + tileHeight + MediaRowMetrics.focusGrowthPadding
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                    subitems: [item]
                )
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: MediaRowMetrics.rowTopInset,
                    leading: 0,
                    bottom: MediaRowMetrics.rowBottomInset,
                    trailing: 0
                )
                return layoutSection
            case .grid:
                // Exact six-across shelf equation: (1920 - 2*52 - 5*8) / 6 = 296.
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0 / 6.0),
                    heightDimension: .absolute(MediaRowMetrics.posterHeight + MediaRowMetrics.focusGrowthPadding)
                ))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(MediaRowMetrics.posterHeight + MediaRowMetrics.focusGrowthPadding)
                    ),
                    repeatingSubitem: item,
                    count: 6
                )
                group.interItemSpacing = .fixed(MediaRowMetrics.posterGap)
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: 18,
                    leading: MediaRowMetrics.rowLeading,
                    bottom: 36,
                    trailing: MediaRowMetrics.rowTrailing
                )
                layoutSection.interGroupSpacing = 18
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .absolute(68)),
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                )
                layoutSection.boundarySupplementaryItems = [header]
                return layoutSection
            }
        }
    }

    // MARK: - Loading

    private func loadInitialContent(forceRefresh: Bool = false) {
        loadTask?.cancel()
        guard provider != nil else {
            showError("The selected media server is no longer available.")
            return
        }

        if sections.isEmpty {
            statusView.apply(.loading)
            collectionView.isHidden = true
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            switch mode {
            case .home:
                await loadHome(forceRefresh: forceRefresh)
            case .library(let library):
                await loadLibrary(library, forceRefresh: forceRefresh)
            case .search:
                break
            }
        }
    }

    private func loadHome(forceRefresh: Bool) async {
        guard let provider else { return }
        if !forceRefresh,
           let cached = await ProviderBrowseCache.shared.homeHubs(providerID: providerID) {
            applyHome(cached)
            return
        }
        do {
            let hubs = try await HomeComposer.compose(provider: provider)
            guard !Task.isCancelled else { return }
            await ProviderBrowseCache.shared.storeHomeHubs(hubs, providerID: providerID)
            applyHome(hubs)
        } catch {
            guard !Task.isCancelled else { return }
            showError(error.localizedDescription)
        }
    }

    private func loadLibrary(_ library: MediaLibrary, forceRefresh: Bool) async {
        guard let provider else { return }
        let page = Page(offset: 0, limit: 60)
        if !forceRefresh,
           let cachedPage = await ProviderBrowseCache.shared.libraryPage(
                providerID: providerID, libraryID: library.id, sort: .addedAtDesc, page: page),
           let cachedHubs = await ProviderBrowseCache.shared.hubs(
                providerID: providerID, libraryID: library.id) {
            applyLibrary(cachedPage, hubs: cachedHubs, library: library, replacing: true)
            return
        }
        do {
            async let pageRequest = provider.items(in: library, sort: .addedAtDesc, page: page)
            async let hubRequest = provider.hubs(in: library)
            let (result, hubs) = try await (pageRequest, hubRequest)
            guard !Task.isCancelled else { return }
            await ProviderBrowseCache.shared.storeLibraryPage(
                result, providerID: providerID, libraryID: library.id, sort: .addedAtDesc, page: page)
            await ProviderBrowseCache.shared.storeHubs(hubs, providerID: providerID, libraryID: library.id)
            applyLibrary(result, hubs: hubs, library: library, replacing: true)
        } catch {
            guard !Task.isCancelled else { return }
            showError(error.localizedDescription)
        }
    }

    private func loadNextLibraryPageIfNeeded(near itemIndex: Int) {
        guard case .library(let library) = mode,
              !loadingNextPage,
              let gridIndex = sections.firstIndex(where: {
                  if case .grid = $0.presentation { return true }
                  return false
              }),
              var section = sections[safe: gridIndex],
              itemIndex >= max(0, section.items.count - 12),
              let page = section.nextPage,
              let provider
        else { return }

        loadingNextPage = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let result: PagedResult<MediaItem>
                if let cached = await ProviderBrowseCache.shared.libraryPage(
                    providerID: providerID, libraryID: library.id, sort: .addedAtDesc, page: page) {
                    result = cached
                } else {
                    result = try await provider.items(in: library, sort: .addedAtDesc, page: page)
                    await ProviderBrowseCache.shared.storeLibraryPage(
                        result, providerID: providerID, libraryID: library.id, sort: .addedAtDesc, page: page)
                }
                guard !Task.isCancelled, sections.indices.contains(gridIndex) else { return }
                let oldCount = section.items.count
                let known = Set(section.items.map(\.ref))
                let additions = result.items.filter { !known.contains($0.ref) }
                section.items.append(contentsOf: additions)
                section.total = result.total
                section.nextPage = result.nextPage
                sections[gridIndex] = section
                if !additions.isEmpty {
                    collectionView.performBatchUpdates {
                        collectionView.insertItems(at: (oldCount..<section.items.count).map {
                            IndexPath(item: $0, section: gridIndex)
                        })
                    }
                    warmArtwork(for: additions)
                }
                loadingNextPage = false
            } catch {
                loadingNextPage = false
                providerBrowseLog.error("Next page failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyHome(_ hubs: [MediaHub]) {
        let nonEmpty = hubs.filter { !$0.items.isEmpty }
        sections = nonEmpty.map { hub in
            Section(
                id: hub.id,
                title: hub.title,
                presentation: .shelf(continueWatching: isContinueWatching(hub)),
                items: unique(hub.items),
                total: hub.items.count,
                nextPage: nil
            )
        }
        applyLoadedContent(emptyTitle: "Your home is ready", emptyMessage: "New and unfinished titles will appear here.")
    }

    private func applyLibrary(
        _ result: PagedResult<MediaItem>,
        hubs: [MediaHub],
        library: MediaLibrary,
        replacing: Bool
    ) {
        let items = unique(result.items)
        if replacing || sections.isEmpty {
            sections = hubs.filter { !$0.items.isEmpty }.map { hub in
                Section(
                    id: hub.id,
                    title: hub.title,
                    presentation: .shelf(continueWatching: isContinueWatching(hub)),
                    items: unique(hub.items),
                    total: hub.items.count,
                    nextPage: nil
                )
            }
            sections.append(Section(
                id: "library:\(library.id)",
                title: "All \(library.title)",
                presentation: .grid,
                items: items,
                total: result.total,
                nextPage: result.nextPage
            ))
        }
        applyLoadedContent(emptyTitle: "No titles", emptyMessage: "This library does not contain any supported videos yet.")
    }

    private func applySearch(_ results: [MediaItem], query: String) {
        let items = unique(results)
        sections = items.isEmpty ? [] : [Section(
            id: "search:\(query)",
            title: "Results",
            presentation: .grid,
            items: items,
            total: items.count,
            nextPage: nil
        )]
        applyLoadedContent(emptyTitle: "No results", emptyMessage: "Try another title, actor, or series.")
    }

    private func applyLoadedContent(emptyTitle: String, emptyMessage: String) {
        collectionView.reloadData()
        if sections.isEmpty {
            collectionView.isHidden = true
            statusView.apply(.empty(title: emptyTitle, message: emptyMessage))
            return
        }
        let wasHidden = collectionView.isHidden
        collectionView.isHidden = false
        statusView.apply(.hidden)
        warmArtwork(for: sections.flatMap(\.items))
        if wasHidden {
            NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    private func showSearchPrompt() {
        collectionView.isHidden = true
        statusView.apply(.prompt(title: "Search", message: "Find movies, series, episodes, and people in Jellyfin."))
    }

    private func showError(_ message: String) {
        collectionView.isHidden = true
        statusView.apply(.error(message: message))
    }

    private func retry() {
        switch mode {
        case .home, .library:
            loadInitialContent(forceRefresh: true)
        case .search:
            let query = lastSearchQuery
            lastSearchQuery = ""
            updateSearchQuery(query)
        }
    }

    private func refreshAfterPlayback() {
        switch mode {
        case .home:
            Task { await ProviderBrowseCache.shared.invalidate(providerID: providerID) }
            loadInitialContent(forceRefresh: true)
        case .library, .search:
            // Detail/player user-state changes are refreshed when the surface
            // is revisited; do not throw away its scroll/focus position here.
            break
        }
    }

    // MARK: - Cells and selection

    private func configureShelfCell(_ cell: ShelfRowCell, sectionIndex: Int) {
        guard sectionIndex < sections.count else { return }
        let sectionID = sections[sectionIndex].id
        let isContinue: Bool
        if case .shelf(let continueWatching) = sections[sectionIndex].presentation {
            isContinue = continueWatching
        } else {
            isContinue = false
        }
        let items = sections[sectionIndex].items
        cell.headerTitle = sections[sectionIndex].title
        cell.cellProvider = { [weak self] collection, indexPath in
            guard let self,
                  let current = self.sections.first(where: { $0.id == sectionID }),
                  indexPath.item < current.items.count else {
                return collection.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
            }
            return self.posterCell(in: collection, at: indexPath, item: current.items[indexPath.item], continueWatching: isContinue)
        }
        cell.onSelect = { [weak self] itemIndex in
            self?.presentDetail(sectionID: sectionID, itemIndex: itemIndex, sourceRow: cell)
        }
        cell.onWillDisplayItem = nil
        cell.onLongPressItem = nil
        cell.onOffsetChanged = nil
        cell.configure(
            kind: isContinue ? .continueWatching : (items.first?.isMusic == true ? .music : .poster),
            realCount: items.count,
            hasSkeleton: false,
            contentToken: contentToken(items),
            initialOffset: 0
        )
    }

    private func posterCell(
        in collection: UICollectionView,
        at indexPath: IndexPath,
        item: MediaItem,
        continueWatching: Bool
    ) -> UICollectionViewCell {
        if continueWatching {
            let cell = collection.dequeueReusableCell(
                withReuseIdentifier: ContinueWatchingCell.reuseID, for: indexPath) as! ContinueWatchingCell
            cell.configure(item: item)
            return cell
        }
        let cell = collection.dequeueReusableCell(
            withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
        cell.configure(item: item)
        return cell
    }

    private func presentDetail(sectionID: String, itemIndex: Int, sourceRow: ShelfRowCell? = nil) {
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionID }),
              itemIndex >= 0, itemIndex < sections[sectionIndex].items.count else { return }
        let items = sections[sectionIndex].items
        let sourcePath = IndexPath(item: sourceRow == nil ? itemIndex : 0, section: sectionIndex)
        pendingFocus = sourcePath
        let sourceFrame: CGRect = {
            if let sourceRow { return sourceRow.frameInWindow(forItem: itemIndex) ?? .zero }
            guard let cell = collectionView.cellForItem(at: sourcePath), let window = view.window else { return .zero }
            return cell.convert(cell.bounds, to: window)
        }()

        let detail = PreviewCarouselViewController(
            items: items,
            selectedIndex: itemIndex,
            sourceFrame: sourceFrame,
            sourceTarget: nil,
            onDismiss: { [weak self, weak sourceRow] _ in
                guard let self else { return }
                sourceRow?.prepareFocusRestore(on: itemIndex)
                self.reportNested(false)
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        )
        reportNested(true)
        present(detail, animated: false)
    }

    // MARK: - Helpers

    private func reportNested(_ nested: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onNestedChange?(nested) }
    }

    private func isContinueWatching(_ hub: MediaHub) -> Bool {
        let normalized = hub.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.contains("continue") || hub.id.lowercased().contains("continue")
    }

    private func unique(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<MediaItemRef>()
        return items.filter { seen.insert($0.ref).inserted }
    }

    private func contentToken(_ items: [MediaItem]) -> Int {
        var hasher = Hasher()
        for item in items { hasher.combine(item.ref) }
        return hasher.finalize()
    }

    private func warmArtwork(for items: [MediaItem]) {
        imageWarmTask?.cancel()
        let urls = Array(items.lazy.compactMap {
            $0.grandparentArtwork?.poster ?? $0.artwork.poster ?? $0.artwork.thumbnail
        }.prefix(24))
        guard !urls.isEmpty else { return }
        imageWarmTask = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { _ = await ImageCacheManager.shared.image(for: url) }
                }
            }
        }
    }
}

extension ProviderBrowseViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard section < sections.count else { return 0 }
        switch sections[section].presentation {
        case .shelf: return 1
        case .grid: return sections[section].items.count
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard indexPath.section < sections.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
        }
        let section = sections[indexPath.section]
        switch section.presentation {
        case .shelf:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            configureShelfCell(cell, sectionIndex: indexPath.section)
            return cell
        case .grid:
            guard indexPath.item < section.items.count else {
                return collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
            }
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            cell.configure(item: section.items[indexPath.item])
            return cell
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: HubHeaderView.reuseID, for: indexPath) as! HubHeaderView
        if indexPath.section < sections.count {
            let section = sections[indexPath.section]
            let title: String
            if let total = section.total, total > section.items.count {
                title = "\(section.title)  ·  \(section.items.count) of \(total)"
            } else {
                title = section.title
            }
            header.configure(title: title, style: .swiftUIInfiniteRow)
        }
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.section < sections.count,
              case .grid = sections[indexPath.section].presentation,
              indexPath.item < sections[indexPath.section].items.count else { return }
        presentDetail(sectionID: sections[indexPath.section].id, itemIndex: indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard indexPath.section < sections.count,
              case .grid = sections[indexPath.section].presentation else { return }
        loadNextLibraryPageIfNeeded(near: indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        guard let next = context.nextFocusedIndexPath else { return }
        NotificationCenter.default.post(name: .contentFocusBelowTopChanged, object: next.section > 0)
    }
}
