import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

/// Captures the outgoing request and returns a canned response so we can prove
/// the composer signs a real owner PoP and hits the real mint endpoint — the
/// exact same transport `SoyehtAPIClient` uses in production (no fake helper).
private final class ClawShareComposerTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 201

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 1024)
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            stream.close()
            captured.httpBody = data
        }
        Self.capturedRequest = captured
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/cbor"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        capturedRequest = nil
        responseData = Data()
        statusCode = 201
    }
}

private struct ClawShareComposerOwnerKeyProvider: OwnerIdentityKeyCreating {
    let key: P256.Signing.PrivateKey

    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        try loadOwnerIdentity(keyReference: "owner-key", publicKey: key.publicKey.compressedRepresentation)
    }

    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        try InMemoryOwnerIdentityKey(publicKey: publicKey, keyReference: keyReference) { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }
}

@Suite("ClawShareComposer", .serialized)
struct ClawShareComposerTests {
    /// Happy path: the composer signs a real owner `Soyeht-PoP` and POSTs a
    /// canonical-CBOR body to the real `/api/v1/claw-share/invites` route.
    @Test func mintSignsRealOwnerPoPAgainstRealEndpoint() async throws {
        ClawShareComposerTestURLProtocol.reset()
        let slotIdBytes = Data((0..<16).map { UInt8($0) })
        ClawShareComposerTestURLProtocol.responseData = HouseholdCBOR.encode(.map([
            "expires_at": .unsigned(1_714_976_400),
            "slot_id": .bytes(slotIdBytes),
            "uri": .text("soyeht://claw-share/v1?e=TESTPAYLOAD"),
            "v": .unsigned(1),
        ]))

        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let state = try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey)
        let storage = InMemoryHouseholdStorage()
        let householdStore = HouseholdSessionStore(storage: storage, account: "active")
        try householdStore.save(state)
        let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

        let composer = ClawShareComposer(apiClient: client)
        let result = try await composer.mintInvite(clawId: "mac-host", ttlSeconds: 3600)

        // Result lifts the engine's response verbatim.
        #expect(result.uri == "soyeht://claw-share/v1?e=TESTPAYLOAD")
        #expect(result.slotId == slotIdBytes)
        #expect(result.expiresAt == 1_714_976_400)

        let request = try #require(ClawShareComposerTestURLProtocol.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/claw-share/invites")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/cbor")

        // Real owner PoP — signed by the device identity, not a bypass.
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("Soyeht-PoP v1:\(state.ownerPersonId):1714972800:"))
        #expect(!authorization.contains("Bearer"))

        // Canonical-CBOR body the engine deserializes into MintInviteRequest.
        let body = try #require(request.httpBody)
        guard case let .map(map) = try HouseholdCBOR.decode(body) else {
            Issue.record("request body is not a CBOR map")
            return
        }
        #expect(map["claw_id"] == .text("mac-host"))
        #expect(map["ttl_secs"] == .unsigned(3600))
        #expect(map["v"] == .unsigned(1))
    }

    /// Authority model: an owner cert lacking `household.invite` authority cannot
    /// mint — the request is rejected **locally, before any network call**. This
    /// is the guarantee that there is no path to an invite without real owner
    /// authority (dropping the caveat invalidates the owner cert outright, so the
    /// PoP layer fails closed with `invalidLocalCert`).
    @Test func mintFailsWithoutInviteAuthority() async throws {
        ClawShareComposerTestURLProtocol.reset()
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let operations = PersonCert.requiredOwnerOperations.subtracting(["household.invite"])
        let state = try makeActiveHouseholdState(
            householdKey: householdKey,
            ownerKey: ownerKey,
            operations: operations
        )
        let storage = InMemoryHouseholdStorage()
        let householdStore = HouseholdSessionStore(storage: storage, account: "active")
        try householdStore.save(state)
        let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

        let composer = ClawShareComposer(apiClient: client)
        do {
            _ = try await composer.mintInvite(clawId: "mac-host")
            Issue.record("mint must fail without owner invite authority")
        } catch is HouseholdPoPError {
            // Expected: the PoP/authority layer rejected it before signing.
        } catch {
            Issue.record("expected HouseholdPoPError, got \(error)")
        }
        // Fail-closed: nothing ever hit the network.
        #expect(ClawShareComposerTestURLProtocol.capturedRequest == nil)
    }

    /// A malformed engine response surfaces as a typed error, never a crash or a
    /// silently-empty invite.
    @Test func mintRejectsMalformedResponse() async throws {
        ClawShareComposerTestURLProtocol.reset()
        ClawShareComposerTestURLProtocol.responseData = Data("not cbor".utf8)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let state = try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey)
        let storage = InMemoryHouseholdStorage()
        let householdStore = HouseholdSessionStore(storage: storage, account: "active")
        try householdStore.save(state)
        let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

        let composer = ClawShareComposer(apiClient: client)
        await #expect(throws: Error.self) {
            _ = try await composer.mintInvite(clawId: "mac-host")
        }
    }

    /// Revoke uses the same real owner-PoP path against the real `/revoke` route,
    /// so every minted invite is revocable.
    @Test func revokeSignsRealOwnerPoPAgainstRealEndpoint() async throws {
        ClawShareComposerTestURLProtocol.reset()
        ClawShareComposerTestURLProtocol.statusCode = 200
        ClawShareComposerTestURLProtocol.responseData = HouseholdCBOR.encode(.map(["v": .unsigned(1)]))
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let state = try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey)
        let storage = InMemoryHouseholdStorage()
        let householdStore = HouseholdSessionStore(storage: storage, account: "active")
        try householdStore.save(state)
        let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

        let slotId = Data((0..<16).map { UInt8($0) })
        let composer = ClawShareComposer(apiClient: client)
        try await composer.revokeInvite(slotId: slotId)

        let request = try #require(ClawShareComposerTestURLProtocol.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/claw-share/revoke")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("Soyeht-PoP v1:\(state.ownerPersonId):1714972800:"))
        let body = try #require(request.httpBody)
        guard case let .map(map) = try HouseholdCBOR.decode(body) else {
            Issue.record("revoke body is not a CBOR map")
            return
        }
        #expect(map["slot_id"] == .bytes(slotId))
        #expect(map["v"] == .unsigned(1))
    }

    /// Pure decode unit: canonical-CBOR `MintInviteResponse` → `ClawShareMintResult`.
    @Test func decodeResponseParsesCanonicalCBOR() throws {
        let slotIdBytes = Data((0..<16).map { _ in UInt8(0xAB) })
        let cbor = HouseholdCBOR.encode(.map([
            "expires_at": .unsigned(42),
            "slot_id": .bytes(slotIdBytes),
            "uri": .text("soyeht://claw-share/v1?e=X"),
            "v": .unsigned(1),
        ]))
        let result = try ClawShareComposer.decodeResponse(cbor)
        #expect(result.uri == "soyeht://claw-share/v1?e=X")
        #expect(result.slotId == slotIdBytes)
        #expect(result.expiresAt == 42)
    }

    @Test func decodeResponseRejectsUnsupportedVersion() throws {
        let cbor = HouseholdCBOR.encode(.map([
            "expires_at": .unsigned(42),
            "slot_id": .bytes(Data(count: 16)),
            "uri": .text("soyeht://x"),
            "v": .unsigned(2),
        ]))
        #expect(throws: ClawShareMintError.versionUnsupported(2)) {
            _ = try ClawShareComposer.decodeResponse(cbor)
        }
    }

    // MARK: - Fixtures (mirror HouseholdAPIClientTests)

    private func makeClient(
        householdStore: HouseholdSessionStore,
        ownerKey: P256.Signing.PrivateKey
    ) -> SoyehtAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClawShareComposerTestURLProtocol.self]
        let defaults = UserDefaults(suiteName: "ClawShareComposerTests.\(UUID().uuidString)")!
        return SoyehtAPIClient(
            session: URLSession(configuration: config),
            store: SessionStore(defaults: defaults, keychainService: "ClawShareComposerTests.\(UUID().uuidString)"),
            householdSessionStore: householdStore,
            ownerIdentityKeyProvider: ClawShareComposerOwnerKeyProvider(key: ownerKey),
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        )
    }

    private func makeActiveHouseholdState(
        householdKey: P256.Signing.PrivateKey,
        ownerKey: P256.Signing.PrivateKey,
        operations: Set<String> = PersonCert.requiredOwnerOperations
    ) throws -> ActiveHouseholdState {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey,
            operations: operations,
            now: now
        )
        let cert = try PersonCert(cbor: certCBOR)
        return ActiveHouseholdState(
            householdId: cert.householdId,
            householdName: "Sample Home",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://home.local:8443")!,
            ownerPersonId: cert.personId,
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "owner-key",
            personCert: cert,
            pairedAt: now,
            lastSeenAt: now
        )
    }
}
