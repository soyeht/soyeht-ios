import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

// Self-contained request-capturing stub, distinctly named (not shared with
// `HouseholdAPIClientTestURLProtocol` in `HouseholdAPIClientTests.swift`) so
// this suite's static state can never race with that one's.
private final class ShareableAppsTestURLProtocol: URLProtocol, @unchecked Sendable {
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

// Local conformer — `HouseholdAPIClientTests.swift`'s own copy is `private`
// to that file, not reachable here.
private struct ShareableAppsOwnerKeyProvider: OwnerIdentityKeyCreating {
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

@Suite("SoyehtAPIClient+ShareableApps", .serialized)
struct ShareableAppsClientTests {

  private func makeClient(
    householdStore: HouseholdSessionStore,
    ownerKey: P256.Signing.PrivateKey
  ) -> SoyehtAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ShareableAppsTestURLProtocol.self]
    let defaults = UserDefaults(suiteName: "ShareableAppsClientTests.\(UUID().uuidString)")!
    return SoyehtAPIClient(
      session: URLSession(configuration: config),
      store: SessionStore(
        defaults: defaults, keychainService: "ShareableAppsClientTests.\(UUID().uuidString)"),
      householdSessionStore: householdStore,
      ownerIdentityKeyProvider: ShareableAppsOwnerKeyProvider(key: ownerKey),
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

  // `clawId` has no default: every call site must state its own value on
  // purpose, so a test can never silently pass because the fixture reused
  // `appId` for both fields (that would hide a decoder bug that copies one
  // field into the other rather than reading `claw_id` independently).
  private func appEntry(
    appId: String,
    clawId: String,
    displayName: String,
    readiness: String
  ) -> HouseholdCBORValue {
    .map([
      "app_id": .text(appId),
      "claw_id": .text(clawId),
      "display_name": .text(displayName),
      "resource": .text("clawsite"),
      "readiness": .text(readiness),
    ])
  }

  // MARK: - List

  @Test func listDecodesAppIdAndClawIdSeparatelyWithNoInstanceIdAnywhere() async throws {
    ShareableAppsTestURLProtocol.reset()
    let appId = "app_" + String(repeating: "a", count: 32)
    // Deliberately NOT equal to `appId` — a decoder bug that copies `app_id`
    // into `clawId` (or vice versa) must fail this assertion, not pass it.
    let clawId = "app_" + String(repeating: "b", count: 32)
    ShareableAppsTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "v": .unsigned(1),
        "apps": .array([
          appEntry(appId: appId, clawId: clawId, displayName: "Study", readiness: "running")
        ]),
      ]))
    let client = try makeReadyClient()

    let apps = try await client.listShareableApps()

    #expect(apps.count == 1)
    #expect(apps[0].appId == appId)
    #expect(apps[0].clawId == clawId)
    #expect(apps[0].appId != apps[0].clawId, "sanity: the fixture must actually exercise two distinct values")
    #expect(apps[0].displayName == "Study")
    #expect(apps[0].readiness == .running)
    // The DTO has no `instanceId`/`instance_id` property at all — decode
    // succeeding from a response that never mentions one is the proof.

    let request = try #require(ShareableAppsTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/v1/household/shareable-apps")
  }

  @Test func listRequiresVersionOne() async throws {
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map(["apps": .array([])]))
    let client = try makeReadyClient()

    await #expect(throws: ShareableAppsError.malformedResponse) {
      _ = try await client.listShareableApps()
    }
  }

  @Test func listRejectsAFutureVersion() async throws {
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map(["v": .unsigned(2), "apps": .array([])]))
    let client = try makeReadyClient()

    await #expect(throws: ShareableAppsError.malformedResponse) {
      _ = try await client.listShareableApps()
    }
  }

  @Test func duplicateDisplayNamesStayIndependentlySelectableByAppId() async throws {
    ShareableAppsTestURLProtocol.reset()
    let firstId = "app_" + String(repeating: "1", count: 32)
    let secondId = "app_" + String(repeating: "2", count: 32)
    ShareableAppsTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "v": .unsigned(1),
        "apps": .array([
          appEntry(appId: firstId, clawId: firstId, displayName: "Study", readiness: "running"),
          appEntry(appId: secondId, clawId: secondId, displayName: "Study", readiness: "running"),
        ]),
      ]))
    let client = try makeReadyClient()

    let apps = try await client.listShareableApps()

    #expect(apps.count == 2)
    #expect(apps[0].displayName == apps[1].displayName)
    #expect(apps[0].id != apps[1].id)
    #expect(Set(apps.map(\.id)).count == 2)
  }

  @Test func unknownReadinessDecodesFailClosedAsUnavailable() async throws {
    ShareableAppsTestURLProtocol.reset()
    let appId = "app_" + String(repeating: "3", count: 32)
    ShareableAppsTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "v": .unsigned(1),
        "apps": .array([
          appEntry(appId: appId, clawId: appId, displayName: "Future App", readiness: "quantum-superposed")
        ]),
      ]))
    let client = try makeReadyClient()

    let apps = try await client.listShareableApps()

    #expect(apps[0].readiness == .unavailable)
    #expect(apps[0].readiness.isRunning == false)
  }

  @Test func listThrowsOnMalformedResponse() async throws {
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.responseData = HouseholdCBOR.encode(.map(["unexpected": .text("shape")]))
    let client = try makeReadyClient()

    await #expect(throws: ShareableAppsError.malformedResponse) {
      _ = try await client.listShareableApps()
    }
  }

  // MARK: - Rename

  @Test func renameUsesAppIdInThePathAndSendsDisplayNameInTheBody() async throws {
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.statusCode = 204
    let appId = "app_" + String(repeating: "4", count: 32)
    let client = try makeReadyClient()

    try await client.renameShareableApp(appID: appId, newDisplayName: "Renamed Study")

    let request = try #require(ShareableAppsTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/v1/household/shareable-apps/\(appId)/rename")

    let body = try #require(request.httpBody)
    guard case .map(let sentFields) = try HouseholdCBOR.decode(body) else {
      Issue.record("Expected a CBOR map body")
      return
    }
    #expect(sentFields["v"] == .unsigned(1))
    #expect(sentFields["display_name"] == .text("Renamed Study"))
    #expect(sentFields.count == 2, "rename must not carry app_id in the body — it is already in the path")
  }

  private func percentEncodedPath(_ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
  }

  @Test func renameEncodesASlashInAppIdSoItCannotEscapeIntoAnotherPathSegment() async throws {
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.statusCode = 204
    let client = try makeReadyClient()
    let adversarialAppID = "app_evil/../household/shareable-apps/other-app/rename"

    try await client.renameShareableApp(appID: adversarialAppID, newDisplayName: "x")

    let request = try #require(ShareableAppsTestURLProtocol.capturedRequest)
    let path = try #require(percentEncodedPath(request))
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    // Fixed prefix (empty, api, v1, household, shareable-apps) + ONE encoded
    // appID segment + rename == 7, regardless of how many `/` the appID
    // itself contained — a raw (unescaped) slash would inflate this count.
    #expect(components.count == 7, "a `/` inside appID must not introduce extra path segments: \(path)")
    #expect(path.hasSuffix("/rename"))
    let encodedSegment = String(components[5])
    #expect(encodedSegment.removingPercentEncoding == adversarialAppID, "must round-trip exactly")
  }

  @Test func renameEncodesAPercentInAppIdWithoutDoubleEncodingHazards() async throws {
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.statusCode = 204
    let client = try makeReadyClient()
    // A literal `%2F` in the raw appID: if this were passed through and only
    // the OTHER `/` got escaped, decoding the path once would resurrect a
    // real slash from user-controlled bytes.
    let adversarialAppID = "app_%2Fsneaky"

    try await client.renameShareableApp(appID: adversarialAppID, newDisplayName: "x")

    let request = try #require(ShareableAppsTestURLProtocol.capturedRequest)
    let path = try #require(percentEncodedPath(request))
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    #expect(components.count == 7)
    let encodedSegment = String(components[5])
    #expect(encodedSegment.removingPercentEncoding == adversarialAppID, "must round-trip exactly, not double-decode")
  }

  @Test func renameOfTheNormalAppIdShapeIsByteIdenticalToRawInterpolation() async throws {
    // The pinned D6 shape (`app_` + 32 lowercase hex) is entirely within
    // `urlPathAllowed` minus `/`, so encoding it must be a complete no-op —
    // the fix for the adversarial cases above must not perturb the normal path.
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.statusCode = 204
    let appId = "app_" + String(repeating: "4", count: 32)
    let client = try makeReadyClient()

    try await client.renameShareableApp(appID: appId, newDisplayName: "x")

    let request = try #require(ShareableAppsTestURLProtocol.capturedRequest)
    #expect(percentEncodedPath(request) == "/api/v1/household/shareable-apps/\(appId)/rename")
  }

  // MARK: - Mint by app_id

  @Test func mintByAppIdSendsAppIdAndOmitsClawIdEntirely() async throws {
    ShareableAppsTestURLProtocol.reset()
    ShareableAppsTestURLProtocol.responseData = HouseholdCBOR.encode(
      .map([
        "uri": .text("soyeht://claw-share/v1?e=device1"),
        "slot_id": .bytes(Data([0x09])),
        "expires_at": .unsigned(1_810_000_900),
      ]))
    let appId = "app_" + String(repeating: "5", count: 32)
    let client = try makeReadyClient()

    let invite = try await client.mintClawShareInvite(appID: appId, ttlSeconds: 3600)

    #expect(invite.uri == "soyeht://claw-share/v1?e=device1")

    let request = try #require(ShareableAppsTestURLProtocol.capturedRequest)
    let body = try #require(request.httpBody)
    guard case .map(let sentFields) = try HouseholdCBOR.decode(body) else {
      Issue.record("Expected a CBOR map body")
      return
    }
    #expect(sentFields["app_id"] == .text(appId))
    #expect(sentFields["ttl_secs"] == .unsigned(3600))
    #expect(sentFields["claw_id"] == nil, "select_mint_target requires exactly one of claw_id/app_id")
  }
}
