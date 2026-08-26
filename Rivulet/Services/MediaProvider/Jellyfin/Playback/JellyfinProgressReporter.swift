// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Reports native Jellyfin playback state. Calls are best-effort so a brief
/// telemetry failure can never interrupt video playback.
struct JellyfinProgressReporter: ProgressReporter {
    let transport: JellyfinTransport
    let token: String
    let context: JellyfinPlaybackReportContext
    private let liveStreamCloser: JellyfinLiveStreamCloser?

    init(
        transport: JellyfinTransport,
        token: String,
        context: JellyfinPlaybackReportContext
    ) {
        self.transport = transport
        self.token = token
        self.context = context
        if let liveStreamID = context.liveStreamID, !liveStreamID.isEmpty {
            liveStreamCloser = JellyfinLiveStreamCloser(
                transport: transport,
                token: token,
                liveStreamID: liveStreamID
            )
        } else {
            liveStreamCloser = nil
        }
    }

    func start() async {
        let body = JellyfinPlaybackStartRequest(context: context, position: 0)
        let _: JellyfinEmptyResponse? = try? await transport.post(
            "/Sessions/Playing", body: body, token: token
        )
    }

    func progress(position: TimeInterval) async {
        let body = JellyfinPlaybackProgressRequest.playing(context: context, position: position)
        let _: JellyfinEmptyResponse? = try? await transport.post(
            "/Sessions/Playing/Progress", body: body, token: token
        )
    }

    func paused(at position: TimeInterval) async {
        let body = JellyfinPlaybackProgressRequest.paused(context: context, position: position)
        let _: JellyfinEmptyResponse? = try? await transport.post(
            "/Sessions/Playing/Progress", body: body, token: token
        )
    }

    func stopped(at position: TimeInterval) async {
        let body = JellyfinPlaybackStopRequest(context: context, position: position)
        let _: JellyfinEmptyResponse? = try? await transport.post(
            "/Sessions/Playing/Stopped", body: body, token: token
        )
        guard let liveStreamCloser else { return }
        // Teardown must survive cancellation of the view/player task. A leaked
        // live stream can hold a tuner or remote source until the server times
        // it out. The actor also makes repeated stop callbacks idempotent.
        let closeTask = Task.detached { await liveStreamCloser.close() }
        await closeTask.value
    }
}

private actor JellyfinLiveStreamCloser {
    private let transport: JellyfinTransport
    private let token: String
    private let liveStreamID: String
    private var didClose = false

    init(transport: JellyfinTransport, token: String, liveStreamID: String) {
        self.transport = transport
        self.token = token
        self.liveStreamID = liveStreamID
    }

    func close() async {
        guard !didClose else { return }
        didClose = true
        let _: JellyfinEmptyResponse? = try? await transport.post(
            "/LiveStreams/Close",
            queryItems: [URLQueryItem(name: "LiveStreamId", value: liveStreamID)],
            token: token
        )
    }
}
