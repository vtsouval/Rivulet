// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct IOSJellyfinLiveChannelSnapshot: Identifiable {
    let channel: UnifiedChannel
    let programs: [UnifiedProgram]
    let currentProgram: UnifiedProgram?
    let classification: IOSLiveTVClassification

    var id: String { channel.id }

    var nextProgram: UnifiedProgram? {
        let boundary = currentProgram?.endTime ?? Date()
        return programs.first { $0.startTime >= boundary }
    }
}

/// Jellyfin-backed electronic programme guide. It reuses the app's UIKit EPG
/// collection so hundreds of channels and thousands of programme cells remain
/// virtualized in both axes rather than becoming an oversized SwiftUI stack.
struct IOSJellyfinLiveGuideView: View {
    let snapshots: [IOSJellyfinLiveChannelSnapshot]
    let onTune: (UnifiedChannel, UnifiedProgram?) async -> Void

    @State private var selection: Selection?
    @State private var snapGeneration = 0

    fileprivate struct Selection: Identifiable {
        let channel: UnifiedChannel
        let program: UnifiedProgram
        var id: String { "\(channel.id)|\(program.id)" }
    }

    var body: some View {
        Group {
            if snapshots.isEmpty {
                ContentUnavailableView(
                    "No guide channels",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Try another country or category.")
                )
            } else {
                IOSGuideCollectionView(
                    channels: guideChannels,
                    programsByChannel: guidePrograms,
                    snapToken: snapGeneration
                ) { channel, program in
                    guard let snapshot = snapshots.first(where: { $0.id == channel.id }) else { return }
                    if let program,
                       let original = snapshot.programs.first(where: {
                           Self.guideProgramID(channelID: snapshot.id, programID: $0.id) == program.id
                       }) {
                        selection = Selection(channel: snapshot.channel, program: original)
                    } else {
                        Task { await onTune(snapshot.channel, snapshot.currentProgram) }
                    }
                }
            }
        }
        .sheet(item: $selection) { value in
            IOSJellyfinGuideProgramSheet(selection: value) {
                selection = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    await onTune(value.channel, value.program)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.clear)
        }
        .onChange(of: snapshots.map(\.id)) { _, _ in snapGeneration += 1 }
        .preferredColorScheme(.dark)
    }

    private var guideChannels: [IOSIPTVChannel] {
        snapshots.map { snapshot in
            IOSIPTVChannel(
                id: snapshot.id,
                name: snapshot.channel.name,
                channelNumber: snapshot.channel.channelNumber,
                tvgID: snapshot.channel.tvgId,
                tvgName: snapshot.channel.name,
                groupTitle: snapshot.classification.category.rawValue,
                logoURL: snapshot.channel.logoURL,
                streamURL: URL(string: "https://jellyfin.invalid/live/\(snapshot.id)")!,
                playbackHeaders: IOSPlaybackHeaders(
                    userAgent: LiveTVClientIdentity.userAgent,
                    authorization: nil,
                    referer: nil
                )
            )
        }
    }

    private var guidePrograms: [String: [IOSEPGProgram]] {
        Dictionary(uniqueKeysWithValues: snapshots.map { snapshot in
            (
                snapshot.id,
                snapshot.programs.map { program in
                    IOSEPGProgram(
                        id: Self.guideProgramID(channelID: snapshot.id, programID: program.id),
                        channelID: snapshot.id,
                        title: program.title,
                        subtitle: program.subtitle,
                        description: program.description,
                        category: program.category,
                        episodeNumber: program.episodeNumber,
                        posterURL: program.posterURL,
                        landscapeURL: program.landscapeURL,
                        start: program.startTime,
                        end: program.endTime,
                        isNew: program.isNew
                    )
                }
            )
        })
    }

    private static func guideProgramID(channelID: String, programID: String) -> String {
        "\(channelID)|\(programID)"
    }
}

private struct IOSJellyfinGuideProgramSheet: View {
    let selection: IOSJellyfinLiveGuideView.Selection
    let onWatch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                IOSGuideDefaultBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            AsyncImage(url: selection.channel.logoURL) { phase in
                                if case .success(let image) = phase { image.resizable().scaledToFit() }
                                else { Image(systemName: "play.tv").font(.title2) }
                            }
                            .frame(width: 58, height: 44)
                            Text(selection.channel.name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }

                        Text(selection.program.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        if let subtitle = selection.program.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.headline).foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Text(selection.program.timeRangeFormatted)
                            if let category = selection.program.category { Text(category) }
                            if let episode = selection.program.episodeNumber { Text(episode) }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                        Button(action: onWatch) {
                            Label("Watch \(selection.channel.name)", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if let description = selection.program.description, !description.isEmpty {
                            Text(description).font(.body).foregroundStyle(.secondary).lineSpacing(3)
                        }
                    }
                    .padding(22)
                }
            }
            .navigationTitle("Programme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
