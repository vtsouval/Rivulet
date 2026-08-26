// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

enum IOSLiveTVCountry: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case greece = "Greece"
    case netherlands = "Netherlands"
    case australia = "Australia"
    case korea = "Korea"
    case unitedKingdom = "United Kingdom"
    case unitedStates = "United States"
    case international = "International"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .all: "🌍"
        case .greece: "🇬🇷"
        case .netherlands: "🇳🇱"
        case .australia: "🇦🇺"
        case .korea: "🇰🇷"
        case .unitedKingdom: "🇬🇧"
        case .unitedStates: "🇺🇸"
        case .international: "🌐"
        }
    }
}

enum IOSLiveTVCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case news = "News"
    case sports = "Sports"
    case movies = "Movies"
    case entertainment = "Entertainment"
    case kids = "Kids"
    case documentary = "Documentary"
    case music = "Music"
    case general = "General"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .news: "newspaper"
        case .sports: "sportscourt"
        case .movies: "film"
        case .entertainment: "sparkles.tv"
        case .kids: "figure.2.and.child.holdinghands"
        case .documentary: "globe.europe.africa"
        case .music: "music.note"
        case .general: "play.tv"
        }
    }
}

struct IOSLiveTVClassification: Sendable {
    let country: IOSLiveTVCountry
    let category: IOSLiveTVCategory
}

enum IOSJellyfinLiveTVClassifier {
    static func classify(channel: UnifiedChannel, program: UnifiedProgram?) -> IOSLiveTVClassification {
        let value = [channel.name, channel.callSign, channel.groupTitle, program?.title, program?.category]
            .compactMap { $0 }.joined(separator: " ").folded
        let category = category(in: value)
        // Sports feeds are presented under Sports, not as a misleading country
        // lineup. Their origin remains available as a future stream preference.
        let country = category == .sports ? .international : country(in: value)
        return IOSLiveTVClassification(country: country, category: category)
    }

    private static func country(in value: String) -> IOSLiveTVCountry {
        if contains(value, ["greece", "greek", "ellada", "ελλαδα", "ελλην", "ert1", "ert2", "ert3", "ert world", "cosmote"]) { return .greece }
        if contains(value, ["netherlands", "dutch", "nederland", "npo 1", "npo 2", "npo 3", "rtl nl"]) { return .netherlands }
        if contains(value, ["australia", "australian", "abc australia", "sbs australia"]) { return .australia }
        if contains(value, ["korea", "korean", "대한민국", "한국", "kbs world", "mbc korea", "sbs korea", "arirang"]) { return .korea }
        if contains(value, ["united kingdom", "british", "bbc one", "bbc two", "itv uk"]) { return .unitedKingdom }
        if contains(value, ["united states", "usa", "american", "abc usa", "cbs usa", "nbc usa"]) { return .unitedStates }
        return .international
    }

    private static func category(in value: String) -> IOSLiveTVCategory {
        if contains(value, ["sport", "football", "soccer", "basketball", "nba", "nfl", "tennis", "formula 1", "f1", "cosmote sport", "nova sport", "espn", "bein"]) { return .sports }
        if contains(value, ["news", "ειδησ", "nieuws", "nieuw", "cnn", "euronews", "bulletin"]) { return .news }
        if contains(value, ["kids", "children", "junior", "cartoon", "disney", "nickelodeon", "παιδ", "anime"]) { return .kids }
        if contains(value, ["documentary", "documentaries", "national geographic", "nat geo", "discovery", "animal planet", "ντοκιμαντερ"]) { return .documentary }
        if contains(value, ["movie", "cinema", "film", "ταιν", "cosmote cinema", "nova cinema"]) { return .movies }
        if contains(value, ["music", "μουσικ", "mtv", "radio"]) { return .music }
        if contains(value, ["entertainment", "series", "σειρ", "lifestyle", "food", "reality"]) { return .entertainment }
        return .general
    }

    private static func contains(_ value: String, _ terms: [String]) -> Bool {
        let padded = " \(value) "
        return terms.contains { padded.contains($0) }
    }
}

private extension String {
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
