import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

// Self-contained, distinctly-named stub — never shared static state with
// `HouseholdAPIClientTestURLProtocol`/`ShareableAppsTestURLProtocol`.
private final class ActiveSharesTestURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var capturedRequest: URLRequest?
  nonisolated(unsafe) static var responseData = Data()
  nonisolated(unsafe) static var statusCode = 200

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
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.responseData)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    capturedRequest = nil
    responseData = Data()
    statusCode = 200
  }
}

private struct ActiveSharesOwnerKeyProvider: OwnerIdentityKeyCreating {
  let key: P256.Signing.PrivateKey

  func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
    try loadOwnerIdentity(
      keyReference: "owner-key", publicKey: key.publicKey.compressedRepresentation)
  }

  func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
    try InMemoryOwnerIdentityKey(publicKey: publicKey, keyReference: keyReference) { payload in
      try key.signature(for: payload).rawRepresentation
    }
  }
}

@Suite("SoyehtAPIClient+ActiveShares", .serialized)
struct ActiveSharesClientTests {

  private func makeClient(
    householdStore: HouseholdSessionStore,
    ownerKey: P256.Signing.PrivateKey
  ) -> SoyehtAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ActiveSharesTestURLProtocol.self]
    let defaults = UserDefaults(suiteName: "ActiveSharesClientTests.\(UUID().uuidString)")!
    return SoyehtAPIClient(
      session: URLSession(configuration: config),
      store: SessionStore(
        defaults: defaults, keychainService: "ActiveSharesClientTests.\(UUID().uuidString)"),
      householdSessionStore: householdStore,
      ownerIdentityKeyProvider: ActiveSharesOwnerKeyProvider(key: ownerKey),
      now: { Date(timeIntervalSince1970: 1_714_972_800) }
    )
  }

  private func makeActiveHouseholdState(
    householdKey: P256.Signing.PrivateKey,
    ownerKey: P256.Signing.PrivateKey
  ) throws -> ActiveHouseholdState {
    let now = Date(timeIntervalSince1970: 1_714_972_800)
    let householdPublicKey = householdKey.publicKey.compressedRepresentation
    let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
    let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
      householdPrivateKey: householdKey,
      personPublicKey: ownerPublicKey,
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

  private func makeReadyClient() throws -> SoyehtAPIClient {
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    return makeClient(householdStore: householdStore, ownerKey: ownerKey)
  }

  private func shareEntry(
    slotId: Data,
    appId: String,
    displayName: String,
    status: String,
    readiness: String,
    createdAt: UInt64,
    expiresAt: UInt64,
    acceptedAt: UInt64? = nil,
    revokedAt: UInt64? = nil
  ) -> HouseholdCBORValue {
    var fields: [String: HouseholdCBORValue] = [
      "slot_id": .bytes(slotId),
      "app_id": .text(appId),
      "display_name": .text(displayName),
      "status": .text(status),
      "readiness": .text(readiness),
      "created_at": .unsigned(createdAt),
      "expires_at": .unsigned(expiresAt),
    ]
    if let acceptedAt { fields["accepted_at"] = .unsigned(acceptedAt) }
    if let revokedAt { fields["revoked_at"] = .unsigned(revokedAt) }
    return .map(fields)
  }

  // MARK: - List

  @Test func listDecodesEveryFieldIncludingOptionalTimestamps() async throws {
    ActiveSharesTestURLProtocol.reset()
    let slotId = Data(repeating: 0xAB, count: 16)
    ActiveSharesTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "v": .unsigned(1),
        "shares": .array([
          shareEntry(
            slotId: slotId, appId: "app_" + String(repeating: "1", count: 32),
            displayName: "Study", status: "accepted", readiness: "running",
            createdAt: 1_000, expiresAt: 9_000, acceptedAt: 2_000
          )
        ]),
      ]))
    let client = try makeReadyClient()

    let shares = try await client.listActiveShares()

    #expect(shares.count == 1)
    #expect(shares[0].slotId == slotId)
    #expect(shares[0].displayName == "Study")
    #expect(shares[0].status == .accepted)
    #expect(shares[0].readiness == .running)
    #expect(shares[0].createdAt == 1_000)
    #expect(shares[0].expiresAt == 9_000)
    #expect(shares[0].acceptedAt == 2_000)
    #expect(shares[0].revokedAt == nil)

    let request = try #require(ActiveSharesTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/v1/claw-share/shares")
  }

  @Test func listRequiresVersionOne() async throws {
    ActiveSharesTestURLProtocol.reset()
    ActiveSharesTestURLProtocol.responseData = HouseholdCBOR.encode(.map(["shares": .array([])]))
    let client = try makeReadyClient()

    await #expect(throws: ActiveSharesError.malformedResponse) {
      _ = try await client.listActiveShares()
    }
  }

  @Test func unknownReadinessDecodesFailClosedAsUnavailable() async throws {
    ActiveSharesTestURLProtocol.reset()
    ActiveSharesTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "v": .unsigned(1),
        "shares": .array([
          shareEntry(
            slotId: Data(repeating: 0x01, count: 16), appId: "app_" + String(repeating: "2", count: 32),
            displayName: "Future App", status: "waiting", readiness: "quantum-superposed",
            createdAt: 1_000, expiresAt: 9_000
          )
        ]),
      ]))
    let client = try makeReadyClient()

    let shares = try await client.listActiveShares()

    #expect(shares[0].readiness == .unavailable)
  }

  @Test func unknownStatusDecodesFailClosedAsRevoked() async throws {
    ActiveSharesTestURLProtocol.reset()
    ActiveSharesTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "v": .unsigned(1),
        "shares": .array([
          shareEntry(
            slotId: Data(repeating: 0x01, count: 16), appId: "app_" + String(repeating: "3", count: 32),
            displayName: "Future App", status: "quantum-shared", readiness: "running",
            createdAt: 1_000, expiresAt: 9_000
          )
        ]),
      ]))
    let client = try makeReadyClient()

    let shares = try await client.listActiveShares()

    #expect(shares[0].status == .revoked, "unrecognized status must fail closed to the most inert case")
  }

  @Test func duplicateAppTwoSharesStayIndependentBySlotId() async throws {
    ActiveSharesTestURLProtocol.reset()
    let appId = "app_" + String(repeating: "4", count: 32)
    let firstSlot = Data(repeating: 0x11, count: 16)
    let secondSlot = Data(repeating: 0x22, count: 16)
    ActiveSharesTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "v": .unsigned(1),
        "shares": .array([
          shareEntry(
            slotId: firstSlot, appId: appId, displayName: "Study", status: "waiting",
            readiness: "running", createdAt: 1_000, expiresAt: 9_000
          ),
          shareEntry(
            slotId: secondSlot, appId: appId, displayName: "Study", status: "accepted",
            readiness: "running", createdAt: 1_500, expiresAt: 9_500, acceptedAt: 2_000
          ),
        ]),
      ]))
    let client = try makeReadyClient()

    let shares = try await client.listActiveShares()

    #expect(shares.count == 2)
    #expect(shares[0].appId == shares[1].appId, "same app on both rows")
    #expect(shares[0].slotId != shares[1].slotId)
    #expect(shares[0].status != shares[1].status, "independent lifecycle per slot, not per app")
  }

  // MARK: - Revoke

  @Test func revokeSendsExactlySlotIdAndVersion() async throws {
    ActiveSharesTestURLProtocol.reset()
    ActiveSharesTestURLProtocol.statusCode = 204
    let slotId = Data(repeating: 0x99, count: 16)
    let client = try makeReadyClient()

    try await client.revokeActiveShare(slotID: slotId)

    let request = try #require(ActiveSharesTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/v1/claw-share/revoke")
    let body = try #require(request.httpBody)
    guard case .map(let sentFields) = try HouseholdCBOR.decode(body) else {
      Issue.record("Expected a CBOR map body")
      return
    }
    #expect(sentFields["v"] == .unsigned(1))
    #expect(sentFields["slot_id"] == .bytes(slotId))
    #expect(sentFields.count == 2)
  }
}
