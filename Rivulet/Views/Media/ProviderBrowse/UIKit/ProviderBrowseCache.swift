// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Small, provider-neutral memory cache for the native browse surface.
///
/// The provider remains the source of truth. This cache only keeps a recently
/// painted page available while the user moves between Home, Search, a library,
/// and a detail modal. It prevents a tab switch from turning into another
/// network round trip without persisting credentials or provider responses.
actor ProviderBrowseCache {
    static let shared = ProviderBrowseCache()

    private struct Entry<Value: Sendable>: Sendable {
        let value: Value
        let storedAt: Date
    }

    private var home: [String: Entry<[MediaHub]>] = [:]
    private var libraries: [String: Entry<PagedResult<MediaItem>>] = [:]
    private var libraryHubs: [String: Entry<[MediaHub]>] = [:]
    private var searches: [String: Entry<[MediaItem]>] = [:]

    private let homeTTL: TimeInterval = 90
    private let libraryTTL: TimeInterval = 180
    private let searchTTL: TimeInterval = 300

    func homeHubs(providerID: String) -> [MediaHub]? {
        fresh(home[providerID], ttl: homeTTL)
    }

    func storeHomeHubs(_ hubs: [MediaHub], providerID: String) {
        home[providerID] = Entry(value: hubs, storedAt: Date())
    }

    func libraryPage(providerID: String, libraryID: String, sort: SortOption, page: Page) -> PagedResult<MediaItem>? {
        fresh(libraries[libraryKey(providerID: providerID, libraryID: libraryID, sort: sort, page: page)], ttl: libraryTTL)
    }

    func storeLibraryPage(
        _ result: PagedResult<MediaItem>,
        providerID: String,
        libraryID: String,
        sort: SortOption,
        page: Page
    ) {
        libraries[libraryKey(providerID: providerID, libraryID: libraryID, sort: sort, page: page)] =
            Entry(value: result, storedAt: Date())
    }

    func hubs(providerID: String, libraryID: String) -> [MediaHub]? {
        fresh(libraryHubs["\(providerID)|\(libraryID)"], ttl: libraryTTL)
    }

    func storeHubs(_ hubs: [MediaHub], providerID: String, libraryID: String) {
        libraryHubs["\(providerID)|\(libraryID)"] = Entry(value: hubs, storedAt: Date())
    }

    func searchResults(providerID: String, query: String) -> [MediaItem]? {
        fresh(searches[searchKey(providerID: providerID, query: query)], ttl: searchTTL)
    }

    func storeSearchResults(_ items: [MediaItem], providerID: String, query: String) {
        searches[searchKey(providerID: providerID, query: query)] = Entry(value: items, storedAt: Date())
    }

    func invalidate(providerID: String) {
        home.removeValue(forKey: providerID)
        libraries = libraries.filter { !$0.key.hasPrefix("\(providerID)|") }
        libraryHubs = libraryHubs.filter { !$0.key.hasPrefix("\(providerID)|") }
        searches = searches.filter { !$0.key.hasPrefix("\(providerID)|") }
    }

    private func fresh<Value: Sendable>(_ entry: Entry<Value>?, ttl: TimeInterval) -> Value? {
        guard let entry, Date().timeIntervalSince(entry.storedAt) <= ttl else { return nil }
        return entry.value
    }

    private func libraryKey(providerID: String, libraryID: String, sort: SortOption, page: Page) -> String {
        "\(providerID)|\(libraryID)|\(String(describing: sort))|\(page.offset)|\(page.limit)"
    }

    private func searchKey(providerID: String, query: String) -> String {
        "\(providerID)|\(query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    }
}
