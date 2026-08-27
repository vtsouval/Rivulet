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

/// Classifies the Jellyfin/Dispatcharr lineup without allowing one country's
/// EPG title to relabel another country's channel. Country comes exclusively
/// from stable channel metadata; the live programme may refine only category.
enum IOSJellyfinLiveTVClassifier {
    static func classify(channel: UnifiedChannel, program: UnifiedProgram?) -> IOSLiveTVClassification {
        let channelValue = [channel.name, channel.callSign, channel.groupTitle]
            .compactMap { $0 }.joined(separator: " ").liveTVFolded
        let categoryValue = [channelValue, program?.title, program?.category]
            .compactMap { $0 }.joined(separator: " ").liveTVFolded
        return IOSLiveTVClassification(
            country: country(in: channelValue),
            category: category(in: categoryValue)
        )
    }

    private static func country(in value: String) -> IOSLiveTVCountry {
        if containsPhrase(value, [
            "greece", "greek", "ellada", "hellas", "ελλαδα", "ελλην",
            "ert world", "ert news", "ert sports", "ertflix", "cosmote tv",
            "cosmote sport", "cosmote cinema", "nova sports", "nova cinema",
            "makedonia tv", "macedonia tv", "open beyond", "vouli tileorasi", "action 24"
        ]) || containsToken(value, [
            "gr", "gri", "ert", "ert1", "ert2", "ert3", "ept", "ept1", "ept2", "ept3",
            "ant1", "antenna", "mega", "star", "alpha", "skai", "σκαι", "open", "mak",
            "kontra", "vouli", "βουλη", "cosmote", "novasports", "novacinema", "action24",
            "attica", "naftemporiki", "ναυτεμπορικη", "parapolitika", "mad", "rise", "4e"
        ]) { return .greece }

        if containsPhrase(value, [
            "netherlands", "dutch", "nederland", "npo 1", "npo 2", "npo 3",
            "rtl nederland", "sbs6", "veronica nl"
        ]) || containsToken(value, ["nl", "nld", "npo1", "npo2", "npo3", "rtl4", "rtl5", "rtl7", "rtl8"]) {
            return .netherlands
        }
        if containsPhrase(value, [
            "australia", "australian", "abc australia", "sbs australia", "channel 7 australia",
            "channel 9 australia", "channel 10 australia"
        ]) || containsToken(value, ["au", "aus", "7two", "7mate", "9gem", "9go", "10bold"]) {
            return .australia
        }
        if containsPhrase(value, [
            "korea", "korean", "대한민국", "한국", "kbs world", "mbc korea", "sbs korea", "arirang"
        ]) || containsToken(value, ["kr", "kor", "kbs1", "kbs2", "mbc", "jtbc", "tvn"]) {
            return .korea
        }
        if containsPhrase(value, [
            "united kingdom", "british", "bbc one", "bbc two", "itv uk", "channel 4 uk", "channel 5 uk"
        ]) || containsToken(value, ["uk", "gb", "bbc1", "bbc2", "itv1", "itv2", "itv3", "itv4"]) {
            return .unitedKingdom
        }
        if containsPhrase(value, [
            "united states", "american", "abc usa", "cbs usa", "nbc usa", "fox usa"
        ]) || containsToken(value, ["us", "usa"]) {
            return .unitedStates
        }
        return .international
    }

    private static func category(in value: String) -> IOSLiveTVCategory {
        if containsPhrase(value, [
            "sport", "football", "soccer", "basketball", "nba", "nfl", "nhl", "mlb", "tennis",
            "formula 1", "f1", "motogp", "cosmote sport", "nova sport", "espn", "bein", "eurosport"
        ]) { return .sports }
        if containsPhrase(value, [
            "news", "ειδησ", "nieuws", "nieuw", "cnn", "euronews", "bulletin", "δελτιο",
            "naftemporiki", "parliament", "vouli"
        ]) { return .news }
        if containsPhrase(value, [
            "kids", "children", "junior", "cartoon", "disney", "nickelodeon", "παιδ", "anime",
            "boomerang", "baby tv"
        ]) { return .kids }
        if containsPhrase(value, [
            "documentary", "documentaries", "national geographic", "nat geo", "discovery",
            "animal planet", "history channel", "ντοκιμαντερ"
        ]) { return .documentary }
        if containsPhrase(value, [
            "movie", "cinema", "film", "ταιν", "cosmote cinema", "nova cinema", "studio universal"
        ]) { return .movies }
        if containsPhrase(value, ["music", "μουσικ", "mtv", "radio", "mad tv", "concert"]) { return .music }
        if containsPhrase(value, [
            "entertainment", "series", "σειρ", "lifestyle", "food", "reality", "comedy", "drama"
        ]) { return .entertainment }
        return .general
    }

    private static func containsPhrase(_ value: String, _ terms: [String]) -> Bool {
        terms.contains { value.contains($0.liveTVFolded) }
    }

    private static func containsToken(_ value: String, _ terms: [String]) -> Bool {
        let normalized = value.replacingOccurrences(
            of: "[^\\p{L}\\p{N}]+",
            with: " ",
            options: .regularExpression
        )
        let padded = " \(normalized) "
        return terms.contains { padded.contains(" \($0.liveTVFolded) ") }
    }
}

private extension String {
    var liveTVFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
