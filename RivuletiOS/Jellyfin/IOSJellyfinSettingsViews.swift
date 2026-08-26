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
    @AppStorage(JellyfinPlaybackPreferences.qualityKey) private var quality = JellyfinPlaybackQuality.auto.rawValue
    @AppStorage("ios.preferredAudioLanguage") private var audioLanguage = "eng"
    @AppStorage("ios.preferredSubtitleLanguage") private var subtitleLanguage = "eng"
    @AppStorage("ios.autoplayNextEpisode") private var autoplayNextEpisode = true
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30

    var body: some View {
        Form {
            Section("Video") {
                Picker("Preferred quality", selection: $quality) {
                    ForEach(JellyfinPlaybackQuality.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Toggle("Auto-play next episode", isOn: $autoplayNextEpisode)
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
            }
        }
        .navigationTitle("Playback")
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
}
