// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

struct IOSJellyfinSecuritySettingsView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @AppStorage("ios.requireDeviceAuthentication") private var appLockEnabled = false
    @State private var records: [JellyfinPasskeyRecord] = []
    @State private var isLoading = true
    @State private var isChangingAppLock = false
    @State private var showingEnrollment = false
    @State private var error: String?

    private var biometryName: String {
        IOSDeviceAuthentication.availableBiometryName() ?? "Device Authentication"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { appLockEnabled },
                    set: { enabled in Task { await changeAppLock(enabled) } }
                )) {
                    Label("Require \(biometryName)", systemImage: "faceid")
                }
                .disabled(isChangingAppLock || IOSDeviceAuthentication.availableBiometryName() == nil)
            } footer: {
                Text("Locks the app after it has been in the background. Your Jellyfin password is never saved.")
            }

            if IOSJellyfinPasskeyCoordinator.isAvailableInThisBuild {
                Section("Passkeys") {
                    if isLoading {
                        HStack { ProgressView(); Text("Loading passkeys…").foregroundStyle(.secondary) }
                    } else if records.isEmpty {
                        ContentUnavailableView(
                            "No passkeys",
                            systemImage: "person.badge.key",
                            description: Text("Add one to sign in with Face ID, Touch ID, or your device passcode.")
                        )
                    } else {
                        ForEach(records) { record in
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.name)
                                    if record.isBackedUp == true {
                                        Text("Synced with iCloud Keychain")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "key.fill").foregroundStyle(.cyan)
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    Task { await remove(record) }
                                }
                            }
                        }
                    }
                    Button("Add Passkey", systemImage: "plus") { showingEnrollment = true }
                }
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Account Security")
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $showingEnrollment) {
            IOSJellyfinPasskeyEnrollmentView {
                showingEnrollment = false
                await reload()
            }
            .environmentObject(jellyfin)
        }
    }

    private func changeAppLock(_ enabled: Bool) async {
        guard enabled != appLockEnabled else { return }
        if !enabled {
            appLockEnabled = false
            return
        }
        isChangingAppLock = true
        defer { isChangingAppLock = false }
        do {
            try await IOSDeviceAuthentication.authenticate(reason: "Enable app lock for Rivulet")
            appLockEnabled = true
            error = nil
        } catch {
            self.error = "App lock was not enabled because authentication was cancelled."
        }
    }

    private func reload() async {
        guard IOSJellyfinPasskeyCoordinator.isAvailableInThisBuild else {
            records = []
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do { records = try await jellyfin.passkeyRecords(); error = nil }
        catch {
            records = []
            self.error = IOSJellyfinSession.message(for: error)
        }
    }

    private func remove(_ record: JellyfinPasskeyRecord) async {
        do {
            try await jellyfin.removePasskey(record)
            withAnimation { records.removeAll { $0.id == record.id } }
            error = nil
        } catch { self.error = IOSJellyfinSession.message(for: error) }
    }
}

private struct IOSJellyfinPasskeyEnrollmentView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var name = Self.defaultName
    @State private var isWorking = false
    @State private var error: String?

    let completed: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Passkey name", text: $name)
                    SecureField("Current Jellyfin password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("The password verifies this one enrollment and is immediately discarded.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Add Passkey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isWorking ? "Adding…" : "Add") { Task { await enroll() } }
                        .disabled(isWorking || password.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isWorking)
    }

    private func enroll() async {
        guard !isWorking else { return }
        isWorking = true
        let submittedPassword = password
        password = ""
        defer { isWorking = false }
        do {
            try await jellyfin.enrollPasskey(
                currentPassword: submittedPassword,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await completed()
        } catch { self.error = IOSJellyfinSession.message(for: error) }
    }

    private static var defaultName: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        return UIDevice.current.model
        #endif
    }
}

struct IOSJellyfinPlaybackSettingsView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @AppStorage(JellyfinPlaybackPreferences.qualityKey) private var quality = JellyfinPlaybackQuality.auto.rawValue
    @AppStorage("ios.preferredAudioLanguage") private var audioLanguage = "eng"
    @AppStorage("ios.preferredSubtitleLanguage") private var subtitleLanguage = "eng"
    @AppStorage("ios.autoplayNextEpisode") private var autoplayNextEpisode = true
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30
    @AppStorage("ios.autoplayTrailers") private var autoplayTrailers = true
    @AppStorage("ios.trailerMuted") private var trailerMuted = true
    @AppStorage("ios.showSkipIntro") private var showSkipIntro = true
    @AppStorage("ios.showSkipCredits") private var showSkipCredits = true
    @AppStorage("ios.cellularQuality") private var cellularQuality = "720p"

    var body: some View {
        Form {
            Section("Video") {
                Picker("Wi-Fi quality", selection: $quality) {
                    ForEach(JellyfinPlaybackQuality.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Picker("Cellular quality", selection: $cellularQuality) {
                    Text("Automatic").tag("auto")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("480p").tag("480p")
                }
                Toggle("Auto-play next episode", isOn: $autoplayNextEpisode)
                Toggle("Auto-play trailers", isOn: $autoplayTrailers)
                Toggle("Start trailers muted", isOn: $trailerMuted)
            }
            Section("Languages") {
                Picker("Audio", selection: $audioLanguage) { languageOptions }
                Picker("Subtitles", selection: $subtitleLanguage) {
                    Text("Off").tag("off")
                    languageOptions
                }
            }
            Section("Skip controls") {
                Stepper("Back \(skipBackwardSeconds) seconds", value: $skipBackwardSeconds, in: 5...60, step: 5)
                Stepper("Forward \(skipForwardSeconds) seconds", value: $skipForwardSeconds, in: 5...120, step: 5)
                Toggle("Show Skip Intro", isOn: $showSkipIntro)
                Toggle("Show Skip Credits", isOn: $showSkipCredits)
            }
        }
        .navigationTitle("Playback")
        .onChange(of: quality) { _, value in
            Task { try? await jellyfin.updateMediaPreferences(.init(preferredResolution: serverResolution(value))) }
        }
        .onChange(of: audioLanguage) { _, value in
            Task { try? await jellyfin.updateMediaPreferences(.init(audioLanguage: value)) }
        }
        .onChange(of: subtitleLanguage) { _, value in
            Task { try? await jellyfin.updateMediaPreferences(.init(subtitleLanguage: value == "off" ? "none" : value)) }
        }
        .onChange(of: autoplayTrailers) { _, value in
            Task {
                try? await jellyfin.updateContentPreferences(.init(trailerPreviewsEnabled: value))
                try? await jellyfin.updateMediaPreferences(.init(trailerAutoplay: value))
            }
        }
        .onChange(of: trailerMuted) { _, value in
            Task { try? await jellyfin.updateMediaPreferences(.init(trailerMuted: value)) }
        }
    }

    @ViewBuilder private var languageOptions: some View {
        Text("English").tag("eng")
        Text("Greek").tag("ell")
        Text("Dutch").tag("nld")
        Text("Korean").tag("kor")
        Text("German").tag("deu")
        Text("Spanish").tag("spa")
        Text("French").tag("fra")
    }

    private func serverResolution(_ value: String) -> String {
        value == "auto" ? "auto" : "\(value)p"
    }
}

struct IOSJellyfinLiveTVSettingsView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var defaultCountry = IOSLiveTVCountry.all.rawValue
    @State private var sportsCountry = IOSLiveTVCountry.greece.rawValue
    @AppStorage("ios.liveTV.startInFavorites") private var startInFavorites = false
    @AppStorage("ios.liveTV.showProgress") private var showProgress = true
    @AppStorage("ios.liveTV.preloadGuide") private var preloadGuide = true

    var body: some View {
        Form {
            Section("Lineup") {
                Picker("Default country", selection: $defaultCountry) {
                    ForEach(IOSLiveTVCountry.allCases) { Text("\($0.flag) \($0.rawValue)").tag($0.rawValue) }
                }
                Picker("Preferred sports feed", selection: $sportsCountry) {
                    ForEach(IOSLiveTVCountry.allCases.filter { $0 != .all && $0 != .international }) {
                        Text("\($0.flag) \($0.rawValue)").tag($0.rawValue)
                    }
                }
                Toggle("Open Favorites first", isOn: $startInFavorites)
            }
            Section("Guide") {
                Toggle("Show programme progress", isOn: $showProgress)
                Toggle("Preload guide data", isOn: $preloadGuide)
            }
        }
        .navigationTitle("Live TV")
        .onAppear {
            let suffix = jellyfin.userName ?? "default"
            defaultCountry = UserDefaults.standard.string(forKey: "ios.liveTV.country.\(suffix)") ?? IOSLiveTVCountry.all.rawValue
            sportsCountry = UserDefaults.standard.string(forKey: "ios.liveTV.sportsCountry.\(suffix)") ?? IOSLiveTVCountry.greece.rawValue
        }
        .onChange(of: defaultCountry) { _, value in
            UserDefaults.standard.set(value, forKey: "ios.liveTV.country.\(jellyfin.userName ?? "default")")
            Task {
                try? await jellyfin.updateContentPreferences(.init(defaultLiveTVCountry: serverCountry(value)))
            }
        }
        .onChange(of: sportsCountry) { _, value in
            UserDefaults.standard.set(value, forKey: "ios.liveTV.sportsCountry.\(jellyfin.userName ?? "default")")
            Task {
                try? await jellyfin.updateContentPreferences(.init(preferredSportsCountry: serverCountry(value)))
            }
        }
    }

    private func serverCountry(_ value: String) -> String {
        switch value {
        case "Netherlands": return "NL"
        case "Australia": return "AU"
        case "Korea": return "KR"
        case "All": return "ALL"
        default: return "GR"
        }
    }
}

struct IOSJellyfinAppearanceSettingsView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @AppStorage("ios.showAnime") private var showAnime = true
    @AppStorage("ios.blurEpisodeSpoilers") private var blurSpoilers = true
    @AppStorage("ios.posterDensity") private var posterDensity = "comfortable"
    @AppStorage("ios.reduceArtworkMotion") private var reduceArtworkMotion = false

    var body: some View {
        Form {
            Section("Discovery") {
                Toggle("Show Anime", isOn: $showAnime)
                Toggle("Blur unwatched episode spoilers", isOn: $blurSpoilers)
            }
            Section("Appearance") {
                Picker("Poster size", selection: $posterDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Large").tag("large")
                }
                Toggle("Reduce artwork motion", isOn: $reduceArtworkMotion)
            }
        }
        .navigationTitle("Discovery & Appearance")
        .onChange(of: showAnime) { _, value in
            Task { try? await jellyfin.updateContentPreferences(.init(animeEnabled: value)) }
        }
        .onChange(of: blurSpoilers) { _, value in
            Task { try? await jellyfin.updateMediaPreferences(.init(hideEpisodeSpoilers: value)) }
        }
    }
}

struct IOSJellyfinStorageSettingsView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @State private var displayedSize = "0 bytes"

    var body: some View {
        Form {
            Section {
                LabeledContent("Catalog snapshots", value: displayedSize)
                Button("Clear cached metadata", systemImage: "trash", role: .destructive) {
                    jellyfin.clearCachedData()
                    displayedSize = jellyfin.cachedDataSize
                }
            } footer: {
                Text("Artwork uses the system URL cache. Clearing metadata never removes watch history or Jellyfin authentication.")
            }
        }
        .navigationTitle("Storage & Cache")
        .onAppear { displayedSize = jellyfin.cachedDataSize }
    }
}
