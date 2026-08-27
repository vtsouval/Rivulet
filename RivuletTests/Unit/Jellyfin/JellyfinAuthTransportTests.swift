// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

final class JellyfinAuthTransportTests: XCTestCase {
    private let identity = JellyfinClientIdentity(
        device: "Test Apple TV",
        deviceID: "test-device-id",
        version: "1.2.3"
    )

    override func setUp() {
        super.setUp()
        JellyfinTestURLProtocol.reset()
    }

    override func tearDown() {
        JellyfinTestURLProtocol.reset()
        super.tearDown()
    }

    func testServerURLAddsSchemeAndRemovesWebClientRoute() throws {
        let url = try JellyfinServerURL.normalize("  media.example.com:8096/jellyfin/web/#/home  ")
        XCTAssertEqual(url.absoluteString, "https://media.example.com:8096/jellyfin")
    }

    func testServerURLPreservesReverseProxySubpathAndDropsQuery() throws {
        let url = try JellyfinServerURL.normalize("https://media.example.com/jellyfin/?api_key=secret")
        XCTAssertEqual(url.absoluteString, "https://media.example.com/jellyfin")
    }

    func testServerURLRejectsUnsupportedSchemeAndCredentials() {
        XCTAssertThrowsError(try JellyfinServerURL.normalize("ftp://media.example.com"))
        XCTAssertThrowsError(try JellyfinServerURL.normalize("https://user:password@media.example.com"))
        XCTAssertThrowsError(try JellyfinServerURL.normalize("http://media.example.com"))
    }

    func testServerURLAllowsExplicitHTTPOnlyForPrivateHosts() throws {
        XCTAssertEqual(
            try JellyfinServerURL.normalize("http://192.168.2.203:8096").absoluteString,
            "http://192.168.2.203:8096"
        )
        XCTAssertEqual(
            try JellyfinServerURL.normalize("http://jellyfin.local:8096").absoluteString,
            "http://jellyfin.local:8096"
        )
    }

    func testAuthorizationHeaderIncludesClientMetadataAndOptionalToken() {
        XCTAssertEqual(
            identity.authorizationHeader(),
            "MediaBrowser Client=\"Rivulet\", Device=\"Test Apple TV\", "
                + "DeviceId=\"test-device-id\", Version=\"1.2.3\""
        )
        XCTAssertEqual(
            identity.authorizationHeader(token: "token-value"),
            "MediaBrowser Client=\"Rivulet\", Device=\"Test Apple TV\", "
                + "DeviceId=\"test-device-id\", Version=\"1.2.3\", Token=\"token-value\""
        )
    }

    func testPublicSystemInfoProbesNormalizedServerBase() async throws {
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/jellyfin/System/Info/Public",
            json: [
                "Id": "server-1",
                "ServerName": "TrueNAS Jellyfin",
                "Version": "10.11.11",
                "ProductName": "Jellyfin Server",
                "StartupWizardCompleted": true
            ]
        )

        let client = try makeClient(serverURL: "https://media.example.com/jellyfin/web/#/home")
        let info = try await client.publicSystemInfo()

        XCTAssertEqual(info.id, "server-1")
        XCTAssertEqual(info.serverName, "TrueNAS Jellyfin")
        XCTAssertEqual(info.version, "10.11.11")
        XCTAssertEqual(JellyfinTestURLProtocol.requests().first?.url?.path, "/jellyfin/System/Info/Public")
    }

    func testAuthenticateByNameBuildsRequestAndReturnsKeychainReadySession() async throws {
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/jellyfin/Users/AuthenticateByName",
            json: [
                "User": [
                    "Id": "user-1",
                    "Name": "Vasilis",
                    "ServerId": "server-1",
                    "HasPassword": true
                ],
                "AccessToken": "access-token",
                "ServerId": "server-1"
            ]
        )

        let client = try makeClient(serverURL: "https://media.example.com/jellyfin/web")
        let session = try await client.authenticate(username: "Vasilis", password: "not-persisted")

        XCTAssertEqual(session.serverURL.absoluteString, "https://media.example.com/jellyfin")
        XCTAssertEqual(session.accessToken, "access-token")
        XCTAssertEqual(session.user.name, "Vasilis")
        XCTAssertEqual(session.providerID, "jellyfin:server-1")
        XCTAssertEqual(session.clientIdentity.deviceID, "test-device-id")

        let request = try XCTUnwrap(JellyfinTestURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == true)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["Username": "Vasilis", "Pw": "not-persisted"])

        let encoded = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(JellyfinAuthenticatedSession.self, from: encoded), session)
    }

    func testCurrentUserUsesAuthorizationTokenAndValidationRejectsUserMismatch() async throws {
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/Users/Me",
            json: ["Id": "another-user", "Name": "Apostolis"]
        )

        let client = try makeClient()
        let stored = JellyfinAuthenticatedSession(
            serverURL: URL(string: "https://media.example.com")!,
            accessToken: "stored-token",
            user: JellyfinUser(
                id: "user-1",
                name: "Vasilis",
                serverID: "server-1",
                primaryImageTag: nil,
                hasPassword: true
            ),
            serverID: "server-1",
            clientIdentity: identity,
            authenticatedAt: Date(timeIntervalSince1970: 1)
        )

        do {
            _ = try await client.validate(stored)
            XCTFail("Expected a user mismatch to invalidate the session")
        } catch let error as JellyfinAPIError {
            XCTAssertEqual(error, .unauthorized(message: nil))
        }

        let request = try XCTUnwrap(JellyfinTestURLProtocol.requests().first)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"stored-token\"") == true)
        XCTAssertNil(request.url?.query)
    }

    func testQuickConnectStartPollAndAuthenticateFlow() async throws {
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/QuickConnect/Initiate",
            json: ["Authenticated": false, "Secret": "a+b&c", "Code": "123456"]
        )
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/QuickConnect/Connect",
            json: ["Authenticated": true, "Secret": "a+b&c", "Code": "123456"]
        )
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/Users/AuthenticateWithQuickConnect",
            json: [
                "User": ["Id": "user-1", "Name": "Vasilis"],
                "AccessToken": "quick-token",
                "ServerId": "server-1"
            ]
        )

        let client = try makeClient()
        let started = try await client.startQuickConnect()
        let polled = try await client.pollQuickConnect(secret: started.secret)
        let session = try await client.authenticateWithQuickConnect(secret: polled.secret)

        XCTAssertFalse(started.authenticated)
        XCTAssertTrue(polled.authenticated)
        XCTAssertEqual(session.accessToken, "quick-token")

        let requests = JellyfinTestURLProtocol.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST"])
        let pollComponents = try XCTUnwrap(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(pollComponents.queryItems, [URLQueryItem(name: "secret", value: "a+b&c")])

        let body = try XCTUnwrap(requests[2].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["Secret": "a+b&c"])
    }

    func testQuickConnectEnabledDecodesBareBoolean() async throws {
        JellyfinTestURLProtocol.enqueueJSONValue(path: "/QuickConnect/Enabled", value: true)

        let client = try makeClient()
        let isEnabled = try await client.isQuickConnectEnabled()
        XCTAssertTrue(isEnabled)
    }

    func testBonfireDevicePairingClaimReturnsValidatedKeychainReadySession() async throws {
        let secret = String(repeating: "a", count: 43)
        let payload = try JellyfinDevicePairingPayload(
            url: URL(string: "https://media.example.com/jellyfin/web/#/quickconnect/claim?secret=\(secret)")!
        )
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/jellyfin/plugins/profiles/device-pairing/claim",
            json: [
                "AccessToken": "paired-token",
                "User": ["Id": "user-1", "Name": "Vasilis"]
            ]
        )
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/jellyfin/Users/Me",
            json: [
                "Id": "user-1",
                "Name": "Vasilis",
                "ServerId": "server-1",
                "HasPassword": true
            ]
        )

        let client = try makeClient(serverURL: "https://media.example.com/jellyfin")
        let session = try await client.authenticateWithDevicePairing(payload: payload)

        XCTAssertEqual(session.accessToken, "paired-token")
        XCTAssertEqual(session.user.name, "Vasilis")
        XCTAssertEqual(session.serverID, "server-1")

        let requests = JellyfinTestURLProtocol.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(requests[0].url?.path, "/jellyfin/plugins/profiles/device-pairing/claim")
        XCTAssertNil(requests[0].url?.query)
        XCTAssertNil(requests[0].url?.fragment)
        XCTAssertFalse(requests[0].value(forHTTPHeaderField: "Authorization")?.contains("Token=") == true)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "Authorization")?.contains("Token=\"paired-token\"") == true)

        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["Secret": secret])
    }

    func testBonfireDevicePairingNeverSendsSecretToAnotherOrigin() async throws {
        let payload = try JellyfinDevicePairingPayload(
            serverURL: URL(string: "https://media.example.com")!,
            secret: String(repeating: "b", count: 43)
        )
        let client = try makeClient(serverURL: "https://other.example.com")

        do {
            _ = try await client.authenticateWithDevicePairing(payload: payload)
            XCTFail("Expected a cross-origin pairing to be rejected")
        } catch let error as JellyfinAPIError {
            XCTAssertEqual(
                error,
                .forbidden(message: "This pairing link belongs to another Jellyfin server.")
            )
        }
        XCTAssertTrue(JellyfinTestURLProtocol.requests().isEmpty)
    }

    func testQuickConnectPayloadRoundTripsWithoutSecretsOrTokens() throws {
        let payload = try JellyfinQuickConnectPayload(
            serverURL: URL(string: "https://media.example.com/jellyfin/web/#/home")!,
            code: "12-34 56"
        )
        let decoded = try JellyfinQuickConnectPayload(url: payload.url)

        XCTAssertEqual(decoded.serverURL.absoluteString, "https://media.example.com/jellyfin")
        XCTAssertEqual(decoded.code, "123456")
        XCTAssertEqual(
            payload.approvalURL.absoluteString,
            "https://media.example.com/jellyfin/web/#/quickconnect?code=123456"
        )
        XCTAssertEqual(
            try JellyfinQuickConnectPayload(url: payload.appURL),
            payload
        )
        XCTAssertFalse(payload.url.absoluteString.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(payload.url.absoluteString.localizedCaseInsensitiveContains("token"))
    }

    func testBonfireDevicePairingPayloadParsesFragmentAndCustomLink() throws {
        let secret = "Abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE"
        XCTAssertEqual(secret.count, 43)
        let payload = try JellyfinDevicePairingPayload(
            url: URL(string: "https://flix.example/jellyfin/web/#/quickconnect/claim?secret=\(secret)")!
        )

        XCTAssertEqual(payload.serverURL.absoluteString, "https://flix.example/jellyfin")
        XCTAssertEqual(payload.secret, secret)
        XCTAssertEqual(try JellyfinDevicePairingPayload(url: payload.appURL), payload)
    }

    func testBonfireDevicePairingPayloadRejectsLeakyOrMalformedLinks() {
        let secret = String(repeating: "c", count: 43)
        XCTAssertThrowsError(try JellyfinDevicePairingPayload(
            url: URL(string: "https://flix.example/web/?secret=\(secret)#/quickconnect/claim")!
        ))
        XCTAssertThrowsError(try JellyfinDevicePairingPayload(
            url: URL(string: "https://flix.example/web/#/quickconnect?secret=\(secret)")!
        ))
        XCTAssertThrowsError(try JellyfinDevicePairingPayload(
            url: URL(string: "https://flix.example/web/#/quickconnect/claim?secret=too-short")!
        ))
        XCTAssertThrowsError(try JellyfinDevicePairingPayload(
            url: URL(string: "https://flix.example/web/#/quickconnect/claim?secret=\(String(repeating: "!", count: 43))")!
        ))
    }

    func testQuickConnectPayloadParsesBonfireApprovalURLWithServerSubpath() throws {
        let payload = try JellyfinQuickConnectPayload(
            url: URL(string: "https://flix.example/jellyfin/web/#/quickconnect?code=654321")!
        )

        XCTAssertEqual(payload.serverURL.absoluteString, "https://flix.example/jellyfin")
        XCTAssertEqual(payload.code, "654321")
        XCTAssertEqual(
            try JellyfinQuickConnectPayload.code(from: payload.approvalURL.absoluteString),
            "654321"
        )
    }

    func testQuickConnectPayloadRejectsForeignSchemesAndInvalidCodes() {
        XCTAssertThrowsError(try JellyfinQuickConnectPayload(
            url: URL(string: "https://attacker.example/quick-connect?server=https://media.example.com&code=123456")!
        ))
        XCTAssertThrowsError(try JellyfinQuickConnectPayload(
            url: URL(string: "https://media.example.com/web/#/home?code=123456")!
        ))
        XCTAssertThrowsError(try JellyfinQuickConnectPayload(
            serverURL: URL(string: "https://media.example.com")!,
            code: "bad/code"
        ))
    }

    func testQuickConnectPayloadOnlyBelongsToExactAuthenticatedServer() throws {
        let payload = try JellyfinQuickConnectPayload(
            serverURL: URL(string: "https://media.example.com/jellyfin")!,
            code: "123456"
        )
        let matching = JellyfinAuthenticatedSession(
            serverURL: URL(string: "https://media.example.com/jellyfin/web")!,
            accessToken: "token",
            user: JellyfinUser(
                id: "user-1",
                name: "Vasilis",
                serverID: "server-1",
                primaryImageTag: nil,
                hasPassword: true
            ),
            serverID: "server-1",
            clientIdentity: identity,
            authenticatedAt: Date(timeIntervalSince1970: 1)
        )
        let foreign = JellyfinAuthenticatedSession(
            serverURL: URL(string: "https://other.example.com/jellyfin")!,
            accessToken: "token",
            user: JellyfinUser(
                id: "user-1",
                name: "Vasilis",
                serverID: "server-2",
                primaryImageTag: nil,
                hasPassword: true
            ),
            serverID: "server-2",
            clientIdentity: identity,
            authenticatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(payload.belongs(to: matching))
        XCTAssertFalse(payload.belongs(to: foreign))
    }

    func testAuthorizeQuickConnectUsesAuthenticatedUserAndNormalizedCode() async throws {
        JellyfinTestURLProtocol.enqueueJSONValue(path: "/QuickConnect/Authorize", value: true)

        let client = try makeClient()
        let authorized = try await client.authorizeQuickConnect(
            code: "12 34-56",
            userID: "user-1",
            accessToken: "access-token"
        )

        XCTAssertTrue(authorized)
        let request = try XCTUnwrap(JellyfinTestURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"access-token\"") == true)
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "code", value: "123456"), URLQueryItem(name: "userId", value: "user-1")]
        )
    }

    func testGenericMutationSupportsQueryJSONBodyAndEmpty204Response() async throws {
        JellyfinTestURLProtocol.enqueueData(path: "/Users/user-1/Items/item-1", statusCode: 204, data: Data())

        let client = try makeClient()
        let response = try await client.transport.requestEmpty(
            "/Users/user-1/Items/item-1",
            method: .put,
            queryItems: [URLQueryItem(name: "mode", value: "replace")],
            token: "access-token",
            body: JellyfinMutationBody(isFavorite: true)
        )

        XCTAssertEqual(response, JellyfinEmptyResponse())
        let request = try XCTUnwrap(JellyfinTestURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "mode", value: "replace")]
        )
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"access-token\"") == true)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        XCTAssertEqual(json, ["IsFavorite": true])
    }

    func testProblemDetailsAndStatusAreMappedWithoutLeakingRequestURL() async throws {
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/Users/Me",
            statusCode: 401,
            json: ["title": "Authentication failed", "status": 401]
        )

        let client = try makeClient()
        do {
            _ = try await client.currentUser(accessToken: "secret-token")
            XCTFail("Expected authentication to fail")
        } catch let error as JellyfinAPIError {
            XCTAssertEqual(error, .unauthorized(message: "Authentication failed"))
            XCTAssertFalse(error.localizedDescription.contains("secret-token"))
        }
    }

    func testAlreadyCancelledTaskDoesNotStartARequest() async throws {
        let client = try makeClient()
        let gate = JellyfinCancellationGate()
        let task = Task {
            await gate.wait()
            return try await client.currentUser(accessToken: "unused")
        }

        await gate.waitUntilBlocked()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(JellyfinTestURLProtocol.requests().isEmpty)
    }

    func testPasskeyStatusAndAuthenticationOptionsUseExpectedContract() async throws {
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/plugins/profiles/passkeys/status",
            json: [
                "Enabled": true,
                "HasPasskey": true,
                "Count": 2,
                "Origin": "https://media.example.com"
            ]
        )
        JellyfinTestURLProtocol.enqueueJSON(
            path: "/plugins/profiles/passkeys/authenticate/options",
            json: [
                "TransactionId": "transaction-1",
                "ExpiresInSeconds": 120,
                "PublicKey": [
                    "challenge": "Y2hhbGxlbmdl",
                    "timeout": 120_000,
                    "rpId": "media.example.com",
                    "allowCredentials": [],
                    "userVerification": "required"
                ]
            ]
        )

        let transport = try makeClient().transport
        let passkeys = JellyfinPasskeyClient(transport: transport)
        let status = try await passkeys.status(userID: "user-1")
        let ceremony = try await passkeys.beginAuthentication(
            userID: "user-1",
            origin: "https://media.example.com/"
        )

        XCTAssertTrue(status.enabled)
        XCTAssertTrue(status.hasPasskey)
        XCTAssertEqual(status.count, 2)
        XCTAssertEqual(ceremony.transactionId, "transaction-1")
        XCTAssertEqual(ceremony.publicKey.rpId, "media.example.com")

        let requests = JellyfinTestURLProtocol.requests()
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "userId", value: "user-1")]
        )
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Origin"), "https://media.example.com")
        let body = try XCTUnwrap(requests[1].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["userId": "user-1"])
    }

    func testPasskeyAuthenticationRejectsNonHTTPSOriginBeforeNetwork() async throws {
        let passkeys = JellyfinPasskeyClient(transport: try makeClient().transport)
        do {
            _ = try await passkeys.beginAuthentication(
                userID: "user-1",
                origin: "http://media.example.com"
            )
            XCTFail("Expected insecure passkey origin to be rejected")
        } catch let error as JellyfinAPIError {
            guard case .forbidden = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(JellyfinTestURLProtocol.requests().isEmpty)
    }

    func testPasskeyAuthenticationRejectsCrossOriginBeforeNetwork() async throws {
        let passkeys = JellyfinPasskeyClient(transport: try makeClient().transport)
        do {
            _ = try await passkeys.beginAuthentication(
                userID: "user-1",
                origin: "https://attacker.example"
            )
            XCTFail("Expected cross-origin passkey ceremony to be rejected")
        } catch let error as JellyfinAPIError {
            guard case .forbidden = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(JellyfinTestURLProtocol.requests().isEmpty)
    }

    func testPasskeyCredentialUsesUnpaddedBase64URL() {
        XCTAssertEqual(Data([0xfb, 0xff, 0x00]).jellyfinBase64URLString, "-_8A")
        XCTAssertEqual("-_8A".jellyfinBase64URLData, Data([0xfb, 0xff, 0x00]))
    }

    private func makeClient(serverURL: String = "https://media.example.com") throws -> JellyfinAuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JellyfinTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = try JellyfinTransport(
            serverURL: serverURL,
            clientIdentity: identity,
            session: session
        )
        return JellyfinAuthClient(transport: transport)
    }
}

private actor JellyfinCancellationGate {
    private var isBlocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        isBlocked = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

nonisolated private struct JellyfinMutationBody: Encodable, Sendable {
    let isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
    }
}

private final class JellyfinTestURLProtocol: URLProtocol {
    private struct Stub {
        let path: String
        let data: Data
        let statusCode: Int
    }

    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var requestHistory: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            stubs = []
            requestHistory = []
        }
    }

    static func enqueueJSON(path: String, statusCode: Int = 200, json: [String: Any]) {
        enqueueJSONValue(path: path, statusCode: statusCode, value: json)
    }

    static func enqueueJSONValue(path: String, statusCode: Int = 200, value: Any) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        enqueueData(path: path, statusCode: statusCode, data: data)
    }

    static func enqueueData(path: String, statusCode: Int = 200, data: Data) {
        lock.withLock {
            stubs.append(Stub(path: path, data: data, statusCode: statusCode))
        }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { requestHistory }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession may convert `httpBody` into an input stream before a
        // custom URLProtocol sees the request. Materialize that stream so the
        // assertions below verify the actual encoded payload on every SDK.
        let recordedRequest = Self.materializedRequestBody(in: request)
        let stub: Stub? = Self.lock.withLock {
            Self.requestHistory.append(recordedRequest)
            guard let index = Self.stubs.firstIndex(where: { $0.path == request.url?.path }) else {
                return nil
            }
            return Self.stubs.remove(at: index)
        }

        guard let stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func materializedRequestBody(in request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let capacity = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        while true {
            let count = stream.read(buffer, maxLength: capacity)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }

        var recorded = request
        recorded.httpBodyStream = nil
        recorded.httpBody = data
        return recorded
    }
}
