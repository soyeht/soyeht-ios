import Testing
import Foundation
import SoyehtCore
@testable import Soyeht

// MARK: - Fake PresenceWebSocket

/// Captures outbound WebSocket frames and exposes `feedServerMessage` to
/// synthesize inbound frames. Lives off the main actor but is only touched
/// from `@MainActor` contexts (MacPresenceClient is `@MainActor`) — the
/// `@unchecked Sendable` escape hatch is honored by the callers.
final class FakePresenceWebSocket: PresenceWebSocket, @unchecked Sendable {
    var sentMessages: [String] = []
    var cancelled = false
    var resumed = false
    private var pendingReceiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    func resume() { resumed = true }

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping (Error?) -> Void) {
        if case .string(let text) = message {
            sentMessages.append(text)
        }
        completionHandler(nil)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        pendingReceiveHandler = completionHandler
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
    }

    /// Synthesize an inbound server frame by invoking the stored receive
    /// completion handler. Returns `true` if a handler was registered.
    @discardableResult
    func feedServerMessage(_ text: String) -> Bool {
        guard let handler = pendingReceiveHandler else { return false }
        pendingReceiveHandler = nil
        handler(.success(.string(text)))
        return true
    }

    func lastMessageJSON() throws -> [String: Any] {
        let last = try #require(sentMessages.last)
        let data = try #require(last.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Fixture

/// Fixed test crypto material. Using deterministic bytes keeps HMAC
/// assertions stable across runs.
private enum Fixture {
    static let macID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let deviceID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    static let secret: Data = Data(repeating: 0xA5, count: 32)
    static let serverNonce: Data = Data(repeating: 0x11, count: 16)
    static let endpoint = MacPresenceClient.Endpoint(host: "127.0.0.1", presencePort: 9999, attachPort: 9998)

    /// `192.0.2.0/24` is RFC 5737 TEST-NET-1, reserved for documentation
    /// and test fixtures. Routes nowhere on the public internet, never
    /// gets assigned to a real device, and signals "this is a stand-in"
    /// to anyone reading the source. Replaces a previously committed
    /// real LAN address (`192.168.15.17`) that leaked the contributor's
    /// home network shape into the public repository.
    static let testHost = "192.0.2.17:57423"
    static let testHostBare = "192.0.2.17"
}

@Suite("PairingCoordinator — reinstall recovery", .serialized)
@MainActor
struct PairingCoordinatorTests {

    @Test("resume ready rebuilds paired Mac registry when UserDefaults were wiped")
    func resumeReadyRebuildsMissingMacRecord() throws {
        let defaultsName = "com.soyeht.tests.pairing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let keychain = KeychainHelper(service: "com.soyeht.tests.pairing.\(UUID().uuidString)")
        defer { keychain.deleteAll() }

        let store = PairedMacsStore(defaults: defaults, keychain: keychain)
        store.storeSecret(Fixture.secret, for: Fixture.macID)
        #expect(store.macs.isEmpty)

        var sentMessages: [String] = []
        let coordinator = PairingCoordinator(
            config: .init(
                macID: Fixture.macID,
                macName: "macStudio",
                pairToken: "unused-on-resume",
                paneNonce: Data(repeating: 0x22, count: 16),
                lastHost: Fixture.testHost
            ),
            store: store,
            send: { sentMessages.append($0) }
        )

        coordinator.start()
        guard case .resumeRequested = coordinator.mode else {
            Issue.record("expected resume mode after start()")
            return
        }
        #expect(sentMessages.last?.contains(PairingMessage.resumeRequest) == true)

        let handled = coordinator.handle(type: PairingMessage.localHandoffReady, payload: [
            "presence_port": 57414,
            "attach_port": 57415,
        ])

        #expect(handled)
        #expect(store.macs.count == 1)
        #expect(store.macs.first?.macID == Fixture.macID)
        #expect(store.macs.first?.name == "macStudio")
        #expect(store.macs.first?.lastHost == Fixture.testHost)
        #expect(store.macs.first?.presencePort == 57414)
        #expect(store.macs.first?.attachPort == 57415)
    }

    @Test("resume denial clears stale local pairing so the next QR can re-pair")
    func deniedResumeClearsStalePairing() throws {
        let defaultsName = "com.soyeht.tests.pairing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let keychain = KeychainHelper(service: "com.soyeht.tests.pairing.\(UUID().uuidString)")
        defer { keychain.deleteAll() }

        let store = PairedMacsStore(defaults: defaults, keychain: keychain)
        store.storeSecret(Fixture.secret, for: Fixture.macID)
        store.upsertMac(
            macID: Fixture.macID,
            name: "macStudio",
            host: Fixture.testHost,
            presencePort: 57414,
            attachPort: 57415
        )
        #expect(store.macs.count == 1)

        let coordinator = PairingCoordinator(
            config: .init(
                macID: Fixture.macID,
                macName: "macStudio",
                pairToken: "unused-on-resume",
                paneNonce: Data(repeating: 0x22, count: 16),
                lastHost: Fixture.testHost
            ),
            store: store,
            send: { _ in }
        )

        _ = coordinator.handle(type: PairingMessage.pairDenied, payload: [
            "reason": PairingDenyReason.challengeFailed,
        ])

        #expect(store.macs.isEmpty)
        #expect(store.hasSecret(for: Fixture.macID) == false)
    }
}

@Suite("PairedMacRegistry", .serialized)
@MainActor
struct PairedMacRegistryTests {

    @Test("existing client connects after migration learns presence endpoint")
    func existingClientConnectsAfterMigrationLearnsEndpoint() async throws {
        let defaultsName = "com.soyeht.tests.registry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let keychain = KeychainHelper(service: "com.soyeht.tests.registry.\(UUID().uuidString)")
        defer { keychain.deleteAll() }

        let store = PairedMacsStore(defaults: defaults, keychain: keychain)
        store.storeSecret(Fixture.secret, for: Fixture.macID)
        store.upsertMac(
            macID: Fixture.macID,
            name: "macStudio",
            host: Fixture.testHost
        )

        var connectURLs: [URL] = []
        var sockets: [FakePresenceWebSocket] = []
        let registry = PairedMacRegistry(store: store) { mac, secret, deviceID, endpoint in
            MacPresenceClient(
                macID: mac.macID,
                deviceID: deviceID,
                secret: secret,
                endpoint: endpoint,
                displayName: mac.name,
                webSocketFactory: { url in
                    connectURLs.append(url)
                    let socket = FakePresenceWebSocket()
                    sockets.append(socket)
                    return socket
                }
            )
        }
        defer {
            registry.clients.values.forEach { $0.disconnect() }
        }

        registry.bootstrap()
        let client = try #require(registry.client(for: Fixture.macID))
        #expect(client.status == .offline("no_endpoint"))
        #expect(connectURLs.isEmpty)

        store.updateEndpoints(
            macID: Fixture.macID,
            host: Fixture.testHost,
            presencePort: 57414,
            attachPort: 57415
        )
        try await settle()

        #expect(connectURLs.count == 1)
        let url = try #require(connectURLs.first)
        #expect(url.host == Fixture.testHostBare)
        #expect(url.port == 57414)
        #expect(url.path == "/presence")
        #expect(url.query?.contains("mac_id=\(Fixture.macID.uuidString)") == true)
        #expect(sockets.count == 1)
        #expect(sockets.first?.resumed == true)
        #expect(client.status == .connecting)
    }
}

/// Drives the handshake to `.authenticated` state. Returns the live client
/// + fake so tests can continue interacting. Explicit about each step so the
/// precondition on `status == .authenticated` is never assumed.
@MainActor
private func authenticatedClient() async throws -> (client: MacPresenceClient, fake: FakePresenceWebSocket) {
    let fake = FakePresenceWebSocket()
    let client = MacPresenceClient(
        macID: Fixture.macID,
        deviceID: Fixture.deviceID,
        secret: Fixture.secret,
        endpoint: Fixture.endpoint,
        displayName: "Test Mac",
        webSocketFactory: { _ in fake }
    )

    // Step 1: open the (fake) socket + register initial receive handler.
    client.connect()
    try await settle()

    // Step 2: simulate the URLSession delegate's didOpen callback. This
    // causes the client to send `presence_hello` with a fresh client nonce.
    client.didOpen()
    try await settle()

    // Step 3: deliver the server `challenge`. The client responds with a
    // `challenge_response` carrying the HMAC.
    let serverNonceB64 = PairingCrypto.base64URLEncode(Fixture.serverNonce)
    let challengeJSON = #"{"type":"\#(PresenceMessage.challenge)","server_nonce":"\#(serverNonceB64)"}"#
    fake.feedServerMessage(challengeJSON)
    try await settle()

    // Step 4: deliver `presence_ready`, which flips status to .authenticated.
    let readyJSON = #"{"type":"\#(PresenceMessage.presenceReady)","display_name":"Test Mac"}"#
    fake.feedServerMessage(readyJSON)
    try await settle()

    #expect(client.status == .authenticated, "precondition: client must be authenticated after presence_ready")
    return (client, fake)
}

/// Yield enough times for the `Task { @MainActor in ... }` hops inside
/// `startReceiveLoop` to drain before the test proceeds.
@MainActor
private func settle() async throws {
    for _ in 0..<8 { await Task.yield() }
    try await Task.sleep(nanoseconds: 5_000_000) // 5ms safety net
    for _ in 0..<8 { await Task.yield() }
}

// MARK: - Tests

@Suite("MacPresenceClient — PR#4 wire handler coverage", .serialized)
@MainActor
struct MacPresenceClientTests {

    @Test("happy handshake: challenge_response HMAC matches PresenceHMACInput")
    func happyHandshake_emitsCorrectHMAC() async throws {
        let fake = FakePresenceWebSocket()
        let client = MacPresenceClient(
            macID: Fixture.macID,
            deviceID: Fixture.deviceID,
            secret: Fixture.secret,
            endpoint: Fixture.endpoint,
            displayName: "Test Mac",
            webSocketFactory: { _ in fake }
        )

        client.connect()
        try await settle()
        client.didOpen()
        try await settle()

        // Capture the client nonce the client advertised in presence_hello.
        let hello = try fake.lastMessageJSON()
        #expect(hello["type"] as? String == PresenceMessage.presenceHello)
        let clientNonceB64 = try #require(hello["client_nonce"] as? String)
        let clientNonce = try #require(PairingCrypto.base64URLDecode(clientNonceB64))

        // Feed the challenge and capture the outbound challenge_response.
        let serverNonceB64 = PairingCrypto.base64URLEncode(Fixture.serverNonce)
        let challengeJSON = #"{"type":"\#(PresenceMessage.challenge)","server_nonce":"\#(serverNonceB64)"}"#
        fake.feedServerMessage(challengeJSON)
        try await settle()

        let response = try fake.lastMessageJSON()
        #expect(response["type"] as? String == PresenceMessage.challengeResponse)
        let actualHMACB64 = try #require(response["hmac"] as? String)
        let actualHMAC = try #require(PairingCrypto.base64URLDecode(actualHMACB64))

        // Independently compute the reference HMAC via the shared helper.
        let expectedParts = PresenceHMACInput.parts(
            serverNonce: Fixture.serverNonce,
            clientNonce: clientNonce,
            deviceID: Fixture.deviceID
        )
        let expectedHMAC = PairingCrypto.hmacSHA256(key: Fixture.secret, messageParts: expectedParts)
        #expect(actualHMAC == expectedHMAC, "HMAC must equal PresenceHMACInput.parts(...) result")
    }

    @Test("attach_denied routes to the matching pane continuation, not the oldest")
    func attachDenied_routesToMatchingPane() async throws {
        let (client, fake) = try await authenticatedClient()

        // Kick off two concurrent attach requests. Both are pending.
        let taskA = Task { try await client.requestAttachGrant(paneID: "pane-A") }
        let taskB = Task { try await client.requestAttachGrant(paneID: "pane-B") }
        try await settle()
        #expect(client.testPendingAttachCount == 2)

        // Deny pane-B only. The fix requires pane-A to stay pending.
        let denyJSON = #"{"type":"\#(PresenceMessage.attachDenied)","pane_id":"pane-B","reason":"token_invalid"}"#
        fake.feedServerMessage(denyJSON)
        try await settle()

        // pane-B should have been rejected.
        do {
            _ = try await taskB.value
            Issue.record("taskB should have thrown — attach_denied targeted pane-B")
        } catch {
            // expected
        }

        // pane-A is still pending. Cancel taskA so the test doesn't hang.
        #expect(client.testPendingAttachCount == 1)
        taskA.cancel()
        client.disconnect()
        _ = try? await taskA.value
    }

    @Test("attach_denied without pane_id is a no-op — does not resolve any continuation")
    func attachDenied_missingPaneID_isNoOp() async throws {
        let (client, fake) = try await authenticatedClient()

        let taskA = Task { try await client.requestAttachGrant(paneID: "pane-A") }
        try await settle()
        #expect(client.testPendingAttachCount == 1)

        // Deny without pane_id — the former "fallback to oldest" bug would
        // have resolved pane-A's continuation; the fix must log + drop.
        let denyJSON = #"{"type":"\#(PresenceMessage.attachDenied)","reason":"token_invalid"}"#
        fake.feedServerMessage(denyJSON)
        try await settle()

        #expect(client.testPendingAttachCount == 1, "pane-A must still be pending — no silent mis-routing")

        taskA.cancel()
        client.disconnect()
        _ = try? await taskA.value
    }

    @Test("panes_snapshot decodes mirrored windows and workspaces")
    func panesSnapshot_decodesMirrorTree() async throws {
        let (client, fake) = try await authenticatedClient()

        let snapshotJSON = """
        {
          "type": "\(PresenceMessage.panesSnapshot)",
          "display_name": "Test Mac",
          "panes": [
            {"id": "pane-1", "title": "@shell", "agent": "shell", "status": "active"}
          ],
          "windows": [
            {
              "id": "win-1",
              "title": "Soyeht",
              "active_workspace_id": "workspace-1",
              "is_key": true,
              "is_main": true,
              "is_visible": true,
              "is_miniaturized": false,
              "workspaces": [
                {
                  "id": "workspace-1",
                  "name": "Main",
                  "kind": "adhoc",
                  "active_pane_id": "pane-1",
                  "is_active": true,
                  "pane_count": 2,
                  "order_index": 0,
                  "layout": {
                    "type": "split",
                    "axis": "vertical",
                    "ratio": 0.5,
                    "children": [
                      {"type": "leaf", "pane_id": "pane-1"},
                      {"type": "leaf", "pane_id": "pane-empty"}
                    ]
                  },
                  "panes": [
                    {"id": "pane-1", "title": "@shell", "agent": "shell", "status": "active", "is_focused": true},
                    {"id": "pane-empty", "title": "no session", "agent": "shell", "status": "idle", "is_live": false, "is_attachable": false}
                  ]
                }
              ]
            }
          ],
          "workspaces": [
            {
              "id": "workspace-1",
              "name": "Main",
              "kind": "adhoc",
              "active_pane_id": "pane-1",
              "is_active": true,
              "pane_count": 2,
              "order_index": 0,
              "layout": {
                "type": "split",
                "axis": "vertical",
                "ratio": 0.5,
                "children": [
                  {"type": "leaf", "pane_id": "pane-1"},
                  {"type": "leaf", "pane_id": "pane-empty"}
                ]
              },
              "panes": [
                {"id": "pane-1", "title": "@shell", "agent": "shell", "status": "active", "is_focused": true},
                {"id": "pane-empty", "title": "no session", "agent": "shell", "status": "idle", "is_live": false, "is_attachable": false}
              ]
            }
          ]
        }
        """
        fake.feedServerMessage(snapshotJSON)
        try await settle()

        #expect(client.panes.map(\.id) == ["pane-1"])
        #expect(client.windows.map(\.id) == ["win-1"])
        #expect(client.windows.first?.workspaces.first?.id == "workspace-1")
        #expect(client.workspaces.first?.orderedPaneRows.first?.pane.isFocused == true)
        #expect(client.workspaces.first?.orderedPaneRows.map { $0.pane.title } == ["@shell", "no session"])
        #expect(client.windows.first?.workspaces.first?.paneCount == 2)
        #expect(client.workspaces.first?.orderedPaneRows.last?.pane.isAttachable == false)
    }
}
