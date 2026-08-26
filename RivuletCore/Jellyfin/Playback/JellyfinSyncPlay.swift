// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation

/// A Jellyfin SyncPlay room exposed to native Apple clients. The participant
/// values are the display names supplied by Jellyfin, not credentials.
nonisolated struct JellyfinSyncPlayGroup: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let participants: [String]
    let state: JellyfinSyncPlayGroupState

    enum CodingKeys: String, CodingKey {
        case id = "GroupId"
        case name = "GroupName"
        case participants = "Participants"
        case state = "State"
    }

    init(id: String, name: String, participants: [String] = [], state: JellyfinSyncPlayGroupState = .idle) {
        self.id = id
        self.name = name
        self.participants = participants
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Watch Together"
        participants = try values.decodeIfPresent([String].self, forKey: .participants) ?? []
        state = try values.decodeIfPresent(JellyfinSyncPlayGroupState.self, forKey: .state) ?? .idle
    }
}

nonisolated enum JellyfinSyncPlayGroupState: String, Codable, Sendable {
    case idle = "Idle"
    case waiting = "Waiting"
    case paused = "Paused"
    case playing = "Playing"
}

nonisolated struct JellyfinSyncPlayQueueSnapshot: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let itemID: String
        let playlistItemID: String
    }

    let items: [Item]
    let playingIndex: Int
    let startPosition: TimeInterval
    let isPlaying: Bool

    var current: Item? {
        guard items.indices.contains(playingIndex) else { return nil }
        return items[playingIndex]
    }
}

nonisolated struct JellyfinSyncPlayCommand: Equatable, Sendable {
    enum Kind: String, Sendable {
        case unpause = "Unpause"
        case pause = "Pause"
        case stop = "Stop"
        case seek = "Seek"
    }

    let kind: Kind
    let position: TimeInterval?
    let executeAt: Date?
    let emittedAt: Date?
    let playlistItemID: String?
}

nonisolated enum JellyfinSyncPlayEvent: Equatable, Sendable {
    case connected
    case disconnected
    case joined(JellyfinSyncPlayGroup)
    case left
    case participantJoined(String)
    case participantLeft(String)
    case groupChanged(JellyfinSyncPlayGroup)
    case stateChanged(JellyfinSyncPlayGroupState)
    case queueChanged(JellyfinSyncPlayQueueSnapshot)
    case command(JellyfinSyncPlayCommand)
    case serverMessage(String)
}

/// Lightweight implementation of Jellyfin's official SyncPlay REST and
/// WebSocket protocol. It intentionally sits beside the app's own transport:
/// no SDK singleton, password, or third-party rendezvous service is involved.
actor JellyfinSyncPlayClient {
    private let transport: JellyfinTransport
    private let token: String
    private let socketSession: URLSession

    private var socketTask: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<JellyfinSyncPlayEvent>.Continuation?
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var serverClockOffset: TimeInterval = 0

    init(
        transport: JellyfinTransport,
        token: String,
        socketSession: URLSession = URLSession(configuration: .default)
    ) {
        self.transport = transport
        self.token = token
        self.socketSession = socketSession
    }

    func connect() -> AsyncStream<JellyfinSyncPlayEvent> {
        if let connectionTask { connectionTask.cancel() }
        socketTask?.cancel(with: .goingAway, reason: nil)

        let (stream, continuation) = AsyncStream<JellyfinSyncPlayEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        eventContinuation?.finish()
        eventContinuation = continuation
        wantsConnection = true
        reconnectAttempt = 0
        connectionTask = Task { [weak self] in await self?.connectionLoop() }
        return stream
    }

    func disconnect() {
        wantsConnection = false
        connectionTask?.cancel()
        connectionTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        eventContinuation?.yield(.disconnected)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func groups() async throws -> [JellyfinSyncPlayGroup] {
        try await transport.get("/SyncPlay/List", token: token)
    }

    @discardableResult
    func createGroup(named name: String) async throws -> JellyfinSyncPlayGroup {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await transport.post(
            "/SyncPlay/New",
            body: NewGroupBody(groupName: clean.isEmpty ? "Watch Together" : clean),
            token: token
        )
    }

    func join(groupID: String) async throws {
        let _: JellyfinEmptyResponse = try await transport.post(
            "/SyncPlay/Join", body: JoinGroupBody(groupID: groupID), token: token
        )
    }

    func leave() async throws {
        let _: JellyfinEmptyResponse = try await transport.post("/SyncPlay/Leave", token: token)
    }

    func startQueue(itemIDs: [String], index: Int, position: TimeInterval) async throws {
        let cleanIDs = itemIDs.filter { !$0.isEmpty }
        guard !cleanIDs.isEmpty else { return }
        let _: JellyfinEmptyResponse = try await transport.post(
            "/SyncPlay/SetNewQueue",
            body: NewQueueBody(
                playingQueue: cleanIDs,
                playingItemPosition: min(max(0, index), cleanIDs.count - 1),
                startPositionTicks: JellyfinTicks.fromSeconds(position)
            ),
            token: token
        )
    }

    func pause() async throws { try await emptyPost("/SyncPlay/Pause") }
    func unpause() async throws { try await emptyPost("/SyncPlay/Unpause") }
    func stop() async throws { try await emptyPost("/SyncPlay/Stop") }

    func seek(to position: TimeInterval) async throws {
        let _: JellyfinEmptyResponse = try await transport.post(
            "/SyncPlay/Seek",
            body: SeekBody(positionTicks: JellyfinTicks.fromSeconds(position)),
            token: token
        )
    }

    func nextItem(currentPlaylistItemID: String) async throws {
        let _: JellyfinEmptyResponse = try await transport.post(
            "/SyncPlay/NextItem",
            body: PlaylistItemBody(playlistItemID: currentPlaylistItemID),
            token: token
        )
    }

    func reportBuffering(
        position: TimeInterval,
        isPlaying: Bool,
        playlistItemID: String
    ) async throws {
        try await reportReadiness(
            path: "/SyncPlay/Buffering",
            position: position,
            isPlaying: isPlaying,
            playlistItemID: playlistItemID
        )
    }

    func reportReady(
        position: TimeInterval,
        isPlaying: Bool,
        playlistItemID: String
    ) async throws {
        try await reportReadiness(
            path: "/SyncPlay/Ready",
            position: position,
            isPlaying: isPlaying,
            playlistItemID: playlistItemID
        )
    }

    private func reportReadiness(
        path: String,
        position: TimeInterval,
        isPlaying: Bool,
        playlistItemID: String
    ) async throws {
        let _: JellyfinEmptyResponse = try await transport.post(
            path,
            body: PlaybackStateBody(
                when: Self.iso8601(Date()),
                positionTicks: JellyfinTicks.fromSeconds(position),
                isPlaying: isPlaying,
                playlistItemID: playlistItemID
            ),
            token: token
        )
    }

    private func emptyPost(_ path: String) async throws {
        let _: JellyfinEmptyResponse = try await transport.post(path, token: token)
    }

    private func connectionLoop() async {
        while wantsConnection, !Task.isCancelled {
            do {
                try await advertiseCapabilities()
                try? await synchronizeClock()
                try await runSocket()
                reconnectAttempt = 0
            } catch is CancellationError {
                break
            } catch {
                eventContinuation?.yield(.disconnected)
                guard wantsConnection, !Task.isCancelled else { break }
                reconnectAttempt = min(reconnectAttempt + 1, 5)
                let delay = min(pow(2, Double(reconnectAttempt - 1)), 16)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func advertiseCapabilities() async throws {
        let _: JellyfinEmptyResponse = try await transport.post(
            "/Sessions/Capabilities",
            queryItems: [
                URLQueryItem(name: "playableMediaTypes", value: "Video"),
                URLQueryItem(name: "supportedCommands", value: "Play,Pause,Seek,Stop"),
                URLQueryItem(name: "supportsMediaControl", value: "true"),
                URLQueryItem(name: "supportsPersistentIdentifier", value: "true")
            ],
            token: token
        )
    }

    private func runSocket() async throws {
        let url = try socketURL()
        var request = URLRequest(url: url)
        request.setValue(
            transport.clientIdentity.authorizationHeader(token: token),
            forHTTPHeaderField: "Authorization"
        )
        let task = socketSession.webSocketTask(with: request)
        socketTask = task
        task.resume()
        eventContinuation?.yield(.connected)

        let keepAlive = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(15))
                try Task.checkCancellation()
                try await task.send(.string("{\"MessageType\":\"KeepAlive\"}"))
            }
        }
        defer {
            keepAlive.cancel()
            task.cancel(with: .goingAway, reason: nil)
            if socketTask === task { socketTask = nil }
        }

        while wantsConnection, !Task.isCancelled {
            let message = try await task.receive()
            let data: Data?
            switch message {
            case .data(let value): data = value
            case .string(let value): data = value.data(using: .utf8)
            @unknown default: data = nil
            }
            if let data, let event = Self.decodeEvent(data) {
                eventContinuation?.yield(adjustedForServerClock(event))
            }
        }
    }

    /// Jellyfin schedules group commands in server UTC. Measuring the offset
    /// once per socket connection keeps remote clients aligned even when their
    /// local clocks differ or the request traverses a tunnel.
    private func synchronizeClock() async throws {
        let requestSent = Date()
        let response: UtcTimeEnvelope = try await transport.get("/GetUtcTime", token: token)
        let responseReceived = Date()
        guard let requestReceived = Self.date(response.requestReceptionTime),
              let responseSent = Self.date(response.responseTransmissionTime) else { return }

        serverClockOffset = (
            requestReceived.timeIntervalSince(requestSent)
                + responseSent.timeIntervalSince(responseReceived)
        ) / 2
        let roundTrip = max(
            0,
            responseReceived.timeIntervalSince(requestSent)
                - responseSent.timeIntervalSince(requestReceived)
        )
        let _: JellyfinEmptyResponse = try await transport.post(
            "/SyncPlay/Ping",
            body: PingBody(ping: Int((roundTrip * 1_000).rounded())),
            token: token
        )
    }

    private func adjustedForServerClock(_ event: JellyfinSyncPlayEvent) -> JellyfinSyncPlayEvent {
        guard case .command(let command) = event,
              let executeAt = command.executeAt else { return event }
        return .command(
            JellyfinSyncPlayCommand(
                kind: command.kind,
                position: command.position,
                executeAt: executeAt.addingTimeInterval(-serverClockOffset),
                emittedAt: command.emittedAt?.addingTimeInterval(-serverClockOffset),
                playlistItemID: command.playlistItemID
            )
        )
    }

    private func socketURL() throws -> URL {
        guard var components = URLComponents(url: transport.baseURL, resolvingAgainstBaseURL: false) else {
            throw JellyfinAPIError.invalidServerURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [components.path, "socket"].filter { !$0.isEmpty && $0 != "/" }.joined(separator: "/")
        components.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "deviceId", value: transport.clientIdentity.deviceID)
        ]
        guard let url = components.url else { throw JellyfinAPIError.invalidServerURL }
        return url
    }

    nonisolated static func decodeEvent(_ data: Data) -> JellyfinSyncPlayEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = root["MessageType"] as? String,
              let payload = root["Data"] as? [String: Any] else { return nil }

        switch messageType {
        case "SyncPlayCommand":
            guard let rawKind = payload["Command"] as? String,
                  let kind = JellyfinSyncPlayCommand.Kind(rawValue: rawKind) else { return nil }
            return .command(
                JellyfinSyncPlayCommand(
                    kind: kind,
                    position: JellyfinTicks.toSeconds(int64(payload["PositionTicks"])),
                    executeAt: date(payload["When"]),
                    emittedAt: date(payload["EmittedAt"]),
                    playlistItemID: payload["PlaylistItemId"] as? String
                )
            )
        case "SyncPlayGroupUpdate":
            return decodeGroupUpdate(payload)
        default:
            return nil
        }
    }

    nonisolated private static func decodeGroupUpdate(_ payload: [String: Any]) -> JellyfinSyncPlayEvent? {
        guard let type = payload["Type"] as? String else { return nil }
        let data = payload["Data"]
        switch type {
        case "GroupJoined":
            guard let group = group(data) else { return nil }
            return .joined(group)
        case "GroupUpdate":
            guard let group = group(data) else { return nil }
            return .groupChanged(group)
        case "GroupLeft", "NotInGroup":
            return .left
        case "UserJoined":
            return .participantJoined(data as? String ?? "Someone")
        case "UserLeft":
            return .participantLeft(data as? String ?? "Someone")
        case "StateUpdate":
            guard let value = data as? [String: Any],
                  let raw = value["State"] as? String,
                  let state = JellyfinSyncPlayGroupState(rawValue: raw) else { return nil }
            return .stateChanged(state)
        case "PlayQueue":
            guard let value = data as? [String: Any],
                  let rawItems = value["Playlist"] as? [[String: Any]] else { return nil }
            let items = rawItems.compactMap { item -> JellyfinSyncPlayQueueSnapshot.Item? in
                guard let itemID = item["ItemId"] as? String,
                      let playlistID = item["PlaylistItemId"] as? String else { return nil }
                return .init(itemID: itemID, playlistItemID: playlistID)
            }
            return .queueChanged(
                JellyfinSyncPlayQueueSnapshot(
                    items: items,
                    playingIndex: int(value["PlayingItemIndex"]) ?? 0,
                    startPosition: JellyfinTicks.toSeconds(int64(value["StartPositionTicks"])) ?? 0,
                    isPlaying: value["IsPlaying"] as? Bool ?? false
                )
            )
        case "GroupDoesNotExist":
            return .serverMessage("That Watch Together group is no longer available.")
        case "LibraryAccessDenied":
            return .serverMessage("A group item is not available to this Jellyfin profile.")
        default:
            return nil
        }
    }

    nonisolated private static func group(_ value: Any?) -> JellyfinSyncPlayGroup? {
        guard let dictionary = value as? [String: Any],
              let id = dictionary["GroupId"] as? String else { return nil }
        let name = dictionary["GroupName"] as? String ?? "Watch Together"
        let participants = dictionary["Participants"] as? [String] ?? []
        let state = (dictionary["State"] as? String).flatMap(JellyfinSyncPlayGroupState.init(rawValue:)) ?? .idle
        return JellyfinSyncPlayGroup(id: id, name: name, participants: participants, state: state)
    }

    nonisolated private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    nonisolated private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    nonisolated private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    nonisolated private static func iso8601(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}

nonisolated private struct NewGroupBody: Encodable, Sendable {
    let groupName: String
    enum CodingKeys: String, CodingKey { case groupName = "GroupName" }
}

nonisolated private struct UtcTimeEnvelope: Decodable, Sendable {
    let requestReceptionTime: String?
    let responseTransmissionTime: String?
    enum CodingKeys: String, CodingKey {
        case requestReceptionTime = "RequestReceptionTime"
        case responseTransmissionTime = "ResponseTransmissionTime"
    }
}

nonisolated private struct PingBody: Encodable, Sendable {
    let ping: Int
    enum CodingKeys: String, CodingKey { case ping = "Ping" }
}

nonisolated private struct JoinGroupBody: Encodable, Sendable {
    let groupID: String
    enum CodingKeys: String, CodingKey { case groupID = "GroupId" }
}

nonisolated private struct NewQueueBody: Encodable, Sendable {
    let playingQueue: [String]
    let playingItemPosition: Int
    let startPositionTicks: Int64
    enum CodingKeys: String, CodingKey {
        case playingQueue = "PlayingQueue"
        case playingItemPosition = "PlayingItemPosition"
        case startPositionTicks = "StartPositionTicks"
    }
}

nonisolated private struct SeekBody: Encodable, Sendable {
    let positionTicks: Int64
    enum CodingKeys: String, CodingKey { case positionTicks = "PositionTicks" }
}

nonisolated private struct PlaylistItemBody: Encodable, Sendable {
    let playlistItemID: String
    enum CodingKeys: String, CodingKey { case playlistItemID = "PlaylistItemId" }
}

nonisolated private struct PlaybackStateBody: Encodable, Sendable {
    let when: String
    let positionTicks: Int64
    let isPlaying: Bool
    let playlistItemID: String
    enum CodingKeys: String, CodingKey {
        case when = "When"
        case positionTicks = "PositionTicks"
        case isPlaying = "IsPlaying"
        case playlistItemID = "PlaylistItemId"
    }
}

/// Main-actor presentation model used by the native Jellyfin player surfaces.
/// It keeps networking and socket reconnection inside
/// `JellyfinSyncPlayClient`, while exposing only stable, UI-ready state.
@MainActor
final class JellyfinSyncPlaySessionModel: ObservableObject {
    @Published private(set) var groups: [JellyfinSyncPlayGroup] = []
    @Published private(set) var activeGroup: JellyfinSyncPlayGroup?
    @Published private(set) var queue: JellyfinSyncPlayQueueSnapshot?
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    var onEvent: ((JellyfinSyncPlayEvent) -> Void)?

    private let client: JellyfinSyncPlayClient
    private var eventTask: Task<Void, Never>?

    init(provider: JellyfinProvider) {
        client = JellyfinSyncPlayClient(
            transport: provider.transport,
            token: provider.session.accessToken
        )
    }

    var isActive: Bool { activeGroup != nil }
    var currentPlaylistItemID: String? { queue?.current?.playlistItemID }

    func connect() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await client.connect()
            await refreshGroups()
            for await event in stream {
                guard !Task.isCancelled else { break }
                apply(event)
                onEvent?(event)
            }
        }
    }

    func disconnect(leavingGroup: Bool) async {
        if leavingGroup, activeGroup != nil { try? await client.leave() }
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        activeGroup = nil
        queue = nil
        isConnected = false
    }

    func refreshGroups() async {
        do {
            groups = try await client.groups().sorted {
                if $0.participants.count != $1.participants.count {
                    return $0.participants.count > $1.participants.count
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func create(
        named name: String,
        itemIDs: [String],
        currentIndex: Int,
        position: TimeInterval
    ) async {
        await perform {
            let group = try await client.createGroup(named: name)
            activeGroup = group
            try await client.startQueue(itemIDs: itemIDs, index: currentIndex, position: position)
            await refreshGroups()
        }
    }

    func join(_ group: JellyfinSyncPlayGroup) async {
        await perform {
            try await client.join(groupID: group.id)
            activeGroup = group
        }
    }

    func leave() async {
        await perform {
            try await client.leave()
            activeGroup = nil
            queue = nil
            await refreshGroups()
        }
    }

    func requestPause() async { await request { try await client.pause() } }
    func requestUnpause() async { await request { try await client.unpause() } }
    func requestStop() async { await request { try await client.stop() } }
    func requestSeek(to position: TimeInterval) async { await request { try await client.seek(to: position) } }

    func requestNextItem() async -> Bool {
        guard let id = currentPlaylistItemID else { return false }
        return await requesting { try await client.nextItem(currentPlaylistItemID: id) }
    }

    func replaceQueue(itemIDs: [String], position: TimeInterval = 0) async -> Bool {
        guard activeGroup != nil, !itemIDs.isEmpty else { return false }
        return await requesting {
            try await client.startQueue(itemIDs: itemIDs, index: 0, position: position)
        }
    }

    func buffering(position: TimeInterval, isPlaying: Bool) async {
        guard let id = currentPlaylistItemID else { return }
        await request(silent: true) {
            try await client.reportBuffering(position: position, isPlaying: isPlaying, playlistItemID: id)
        }
    }

    func ready(position: TimeInterval, isPlaying: Bool) async {
        guard let id = currentPlaylistItemID else { return }
        await request(silent: true) {
            try await client.reportReady(position: position, isPlaying: isPlaying, playlistItemID: id)
        }
    }

    private func apply(_ event: JellyfinSyncPlayEvent) {
        switch event {
        case .connected:
            isConnected = true
        case .disconnected:
            isConnected = false
        case .joined(let group), .groupChanged(let group):
            activeGroup = group
        case .left:
            activeGroup = nil
            queue = nil
        case .participantJoined(let name):
            updateParticipants(adding: name)
        case .participantLeft(let name):
            updateParticipants(removing: name)
        case .stateChanged(let state):
            guard let group = activeGroup else { break }
            activeGroup = JellyfinSyncPlayGroup(
                id: group.id,
                name: group.name,
                participants: group.participants,
                state: state
            )
        case .queueChanged(let snapshot):
            queue = snapshot
        case .serverMessage(let value):
            message = value
        case .command:
            break
        }
    }

    private func updateParticipants(adding name: String? = nil, removing: String? = nil) {
        guard let group = activeGroup else { return }
        var participants = group.participants
        if let name, !participants.contains(name) { participants.append(name) }
        if let removing { participants.removeAll { $0 == removing } }
        activeGroup = JellyfinSyncPlayGroup(
            id: group.id,
            name: group.name,
            participants: participants,
            state: group.state
        )
    }

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        do { try await operation() }
        catch { message = error.localizedDescription }
    }

    private func request(silent: Bool = false, _ operation: () async throws -> Void) async {
        do { try await operation() }
        catch { if !silent { message = error.localizedDescription } }
    }

    private func requesting(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}
