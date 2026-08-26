// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Stable metadata Jellyfin uses to identify this client installation.
///
/// `deviceID` must be generated once by the host and persisted. It is not a
/// hardware identifier and must not change between launches, otherwise
/// Jellyfin will create a new device session on every sign-in.
nonisolated struct JellyfinClientIdentity: Codable, Hashable, Sendable {
    let client: String
    let device: String
    let deviceID: String
    let version: String

    init(client: String = "Rivulet", device: String, deviceID: String, version: String) {
        self.client = client
        self.device = device
        self.deviceID = deviceID
        self.version = version
    }

    func authorizationHeader(token: String? = nil) -> String {
        var fields = [
            "Client=\"\(Self.escapedHeaderValue(client))\"",
            "Device=\"\(Self.escapedHeaderValue(device))\"",
            "DeviceId=\"\(Self.escapedHeaderValue(deviceID))\"",
            "Version=\"\(Self.escapedHeaderValue(version))\""
        ]
        if let token, !token.isEmpty {
            fields.append("Token=\"\(Self.escapedHeaderValue(token))\"")
        }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    private static func escapedHeaderValue(_ value: String) -> String {
        value.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .map { String($0) }
            .joined()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

nonisolated struct JellyfinUser: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let serverID: String?
    let primaryImageTag: String?
    let hasPassword: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverID = "ServerId"
        case primaryImageTag = "PrimaryImageTag"
        case hasPassword = "HasPassword"
    }
}

/// All data needed to restore and validate a Jellyfin session.
///
/// This value contains an access token and is suitable for encoding into one
/// Keychain item. It must never be written to UserDefaults or diagnostics.
nonisolated struct JellyfinAuthenticatedSession: Codable, Hashable, Sendable {
    let serverURL: URL
    let accessToken: String
    let user: JellyfinUser
    let serverID: String?
    let clientIdentity: JellyfinClientIdentity
    let authenticatedAt: Date

    var providerID: String {
        if let serverID, !serverID.isEmpty {
            return "jellyfin:\(serverID)"
        }
        return "jellyfin:\(serverURL.host ?? serverURL.absoluteString)"
    }
}

nonisolated struct JellyfinQuickConnectState: Codable, Hashable, Sendable {
    let authenticated: Bool
    let secret: String
    let code: String
    let deviceID: String?
    let deviceName: String?
    let appName: String?
    let appVersion: String?
    let dateAdded: String?

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
        case deviceID = "DeviceId"
        case deviceName = "DeviceName"
        case appName = "AppName"
        case appVersion = "AppVersion"
        case dateAdded = "DateAdded"
    }
}

nonisolated struct JellyfinPublicSystemInfo: Codable, Hashable, Sendable {
    let id: String
    let serverName: String
    let version: String
    let productName: String?
    let startupWizardCompleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case startupWizardCompleted = "StartupWizardCompleted"
    }
}

nonisolated struct JellyfinAuthenticationResult: Decodable, Sendable {
    let user: JellyfinUser
    let accessToken: String
    let serverID: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverID = "ServerId"
    }
}

nonisolated struct JellyfinUsernamePasswordRequest: Encodable, Sendable {
    let username: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

nonisolated struct JellyfinQuickConnectAuthenticationRequest: Encodable, Sendable {
    let secret: String

    enum CodingKeys: String, CodingKey {
        case secret = "Secret"
    }
}
