import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdMachinesClient")
struct HouseholdMachinesClientTests {
    @Test func fetchesOwnerAuthenticatedInventoryAndBuildsStrictSelfAuthority() async throws {
        let other = try MachineFixture(seed: 0x11, isSelf: false, hostLabel: "linux-alpha")
        let selfMachine = try MachineFixture(seed: 0x22, isSelf: true, hostLabel: "mac-alpha")
        let requestBox = RequestBox()
        let signingOwner = RecordingOwner()
        let client = makeClient(
            body: try responseData(
                householdID: "hh_example",
                selfMachineID: selfMachine.machineID,
                machines: [other, selfMachine]
            ),
            signer: HouseholdPoPSigner(
                ownerIdentity: signingOwner,
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            requestBox: requestBox,
            baseURL: URL(string: "https://engine.example.test/bootstrap")!
        )

        let snapshot = try await client.fetch()

        #expect(snapshot.householdID == "hh_example")
        #expect(snapshot.machines.map(\.machineID) == [other.id, selfMachine.id])
        #expect(snapshot.selfMachine.machineID == selfMachine.id)
        #expect(snapshot.selfMachine.hostLabel == "mac-alpha")
        #expect(snapshot.reachabilityAuthority.householdID == "hh_example")
        #expect(snapshot.reachabilityAuthority.selfMachineID == selfMachine.id)

        let request = try #require(requestBox.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/bootstrap/api/v1/household/machines")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        #expect(request.httpBody == nil)

        let expectedSigningContext = HouseholdCBOR.requestSigningContext(
            method: "GET",
            pathAndQuery: "/bootstrap/api/v1/household/machines",
            timestamp: 1_800_000_000,
            bodyHash: HouseholdHash.blake3(Data())
        )
        #expect(signingOwner.lastPayload == expectedSigningContext)
    }

    @Test func rejectsWrongEnvelopeVersionAndHousehold() async throws {
        let machine = try MachineFixture(seed: 0x22, isSelf: true)

        let wrongVersion = makeClient(body: try responseData(
            version: 2,
            householdID: "hh_example",
            selfMachineID: machine.machineID,
            machines: [machine]
        ))
        await expectError(.unsupportedEnvelopeVersion(2), from: wrongVersion)

        let wrongHousehold = makeClient(body: try responseData(
            householdID: "hh_other",
            selfMachineID: machine.machineID,
            machines: [machine]
        ))
        await expectError(
            .householdIDMismatch(expected: "hh_example", actual: "hh_other"),
            from: wrongHousehold
        )
    }

    @Test func rejectsInvalidOrMismatchedMachineIdentity() async throws {
        let machine = try MachineFixture(seed: 0x22, isSelf: true)

        var malformedKey = machine
        malformedKey.machinePublicKey = "02" + String(repeating: "ff", count: 32)
        let malformed = makeClient(body: try responseData(
            householdID: "hh_example",
            selfMachineID: malformedKey.machineID,
            machines: [malformedKey]
        ))
        await expectError(.invalidMachinePublicKey, from: malformed)

        var mismatchedIdentifier = machine
        mismatchedIdentifier.machineID = "m_not_the_key"
        let mismatch = makeClient(body: try responseData(
            householdID: "hh_example",
            selfMachineID: mismatchedIdentifier.machineID,
            machines: [mismatchedIdentifier]
        ))
        await expectError(.machineIdentifierMismatch, from: mismatch)

        var uppercaseKey = machine
        uppercaseKey.machinePublicKey = uppercaseKey.machinePublicKey.uppercased()
        let uppercase = makeClient(body: try responseData(
            householdID: "hh_example",
            selfMachineID: uppercaseKey.machineID,
            machines: [uppercaseKey]
        ))
        await expectError(.invalidMachinePublicKey, from: uppercase)
    }

    @Test func rejectsMissingOrContradictorySelfBinding() async throws {
        let first = try MachineFixture(seed: 0x22, isSelf: true)
        let second = try MachineFixture(seed: 0x33, isSelf: false)

        let missing = makeClient(body: try responseData(
            householdID: "hh_example",
            selfMachineID: nil,
            machines: [first]
        ))
        await expectError(.missingSelfMachineIdentifier, from: missing)

        let reportedNonSelf = makeClient(body: try responseData(
            householdID: "hh_example",
            selfMachineID: second.machineID,
            machines: [first, second]
        ))
        await expectError(.inconsistentSelfMachineBinding, from: reportedNonSelf)

        var secondSelf = second
        secondSelf.isSelf = true
        let multipleSelf = makeClient(body: try responseData(
            householdID: "hh_example",
            selfMachineID: first.machineID,
            machines: [first, secondSelf]
        ))
        await expectError(.inconsistentSelfMachineBinding, from: multipleSelf)

        var duplicate = first
        duplicate.hostLabel = "mac-beta"
        let duplicatedID = makeClient(body: try responseData(
            householdID: "hh_example",
            selfMachineID: first.machineID,
            machines: [first, duplicate]
        ))
        await expectError(.duplicateMachineIdentifier, from: duplicatedID)
    }

    @Test func authorityBootstrapperUsesTheSingleLegacySeedOnlyForMachinesRead() async throws {
        let machine = try MachineFixture(seed: 0x22, isSelf: true, hostLabel: "mac-alpha")
        let storage = InMemoryHouseholdStorage()
        let sessionStore = HouseholdSessionStore(storage: storage, account: "machines-bootstrap")
        let endpoint = URL(string: "https://engine.example.test:8443/legacy-seed")!
        try sessionStore.save(try activeState(householdID: "hh_example", endpoint: endpoint))

        let requestBox = RequestBox()
        let bootstrapper = MachineReachabilityAuthorityBootstrapper(
            sessionStore: sessionStore,
            transport: { request in
                requestBox.set(request)
                return (
                    try responseData(
                        householdID: "hh_example",
                        selfMachineID: machine.machineID,
                        machines: [machine]
                    ),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json; charset=utf-8"]
                    )!
                )
            }
        )

        let snapshot = try await bootstrapper.bootstrap(
            popSigner: HouseholdPoPSigner(ownerIdentity: RecordingOwner())
        )

        #expect(snapshot.reachabilityAuthority.selfMachineID == machine.id)
        #expect(requestBox.request?.url?.absoluteString ==
            "https://engine.example.test:8443/legacy-seed/api/v1/household/machines")

        let reachability = MachineReachability(
            authority: snapshot.reachabilityAuthority,
            sessionStore: sessionStore
        )
        let resolution = await reachability.candidates(
            machineID: snapshot.selfMachine.machineID,
            purpose: .identitySnapshot
        )
        guard case let .candidates(primary, fallbacks) = resolution else {
            Issue.record("Expected post-authority resolution through the seam")
            return
        }
        #expect(primary.baseURL == endpoint)
        #expect(fallbacks.isEmpty)
    }

    @Test func mapsAuthorizationAndHTTPFailures() async throws {
        let machine = try MachineFixture(seed: 0x22, isSelf: true)
        let unauthorized = makeClient(
            body: Data(),
            status: 401,
            contentType: "application/json"
        )
        await expectError(.unauthorized, from: unauthorized)

        let wrongContentType = makeClient(
            body: try responseData(
                householdID: "hh_example",
                selfMachineID: machine.machineID,
                machines: [machine]
            ),
            contentType: "application/cbor"
        )
        await expectError(.unexpectedContentType("application/cbor"), from: wrongContentType)

        let malformedJSON = makeClient(body: Data("not json".utf8))
        await expectError(.unexpectedResponse, from: malformedJSON)
    }

    @Test func rejectsRawLegacyIdentifierOnlyMachineRecordWithoutPublicKey() async throws {
        let machine = try MachineFixture(seed: 0x22, isSelf: true)
        let rawIdentifierOnlyRecord: [String: Any] = [
            "machine_id": machine.machineID,
            "host_label": "mac-alpha",
            "platform": "macos",
            "is_self": true,
            "capabilities": ["engine", "pty"],
            "joined_at": 1_725_000_000
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "hh_id": "hh_example",
            "self_m_id": machine.machineID,
            "machines": [rawIdentifierOnlyRecord]
        ])

        await expectError(.unexpectedResponse, from: makeClient(body: body))
    }
}

private extension HouseholdMachinesClientTests {
    struct MachineFixture: Encodable {
        var machineID: String
        var machinePublicKey: String
        var hostLabel: String
        let platform: String
        var isSelf: Bool
        let capabilities: [String]
        let joinedAt: UInt64
        let id: MachineID

        init(seed: UInt8, isSelf: Bool, hostLabel: String = "machine-alpha") throws {
            let key = try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: seed, count: 32)
            )
            let publicKey = key.publicKey.compressedRepresentation
            let id = try MachineID(authenticatedMachinePublicKey: publicKey)
            self.machineID = id.rawValue
            self.machinePublicKey = Self.lowerHex(publicKey)
            self.hostLabel = hostLabel
            self.platform = "macos"
            self.isSelf = isSelf
            self.capabilities = ["engine", "pty"]
            self.joinedAt = 1_725_000_000
            self.id = id
        }

        enum CodingKeys: String, CodingKey {
            case machineID = "machine_id"
            case machinePublicKey = "machine_pub"
            case hostLabel = "host_label"
            case platform
            case isSelf = "is_self"
            case capabilities
            case joinedAt = "joined_at"
        }

        private static func lowerHex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }
    }

    struct WireResponse: Encodable {
        let version: UInt64
        let householdID: String
        let selfMachineID: String?
        let machines: [MachineFixture]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case householdID = "hh_id"
            case selfMachineID = "self_m_id"
            case machines
        }
    }

    final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?

        var request: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            stored = request
        }
    }

    final class RecordingOwner: OwnerIdentitySigning, @unchecked Sendable {
        let personId = "p_owner"
        let publicKey = Data(repeating: 0x02, count: 33)
        let keyReference = "test-owner-key"

        private let lock = NSLock()
        private var payload: Data?

        var lastPayload: Data? {
            lock.lock()
            defer { lock.unlock() }
            return payload
        }

        func sign(_ payload: Data) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            self.payload = payload
            return Data(repeating: 0x11, count: 64)
        }
    }

    final class InMemoryHouseholdStorage: HouseholdSecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func save(_ data: Data, account: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            values[account] = data
            return true
        }

        func load(account: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return values[account]
        }

        func delete(account: String) {
            lock.lock()
            defer { lock.unlock() }
            values.removeValue(forKey: account)
        }
    }

    func makeClient(
        body: Data,
        status: Int = 200,
        contentType: String = "application/json",
        signer: HouseholdPoPSigner = HouseholdPoPSigner(ownerIdentity: RecordingOwner()),
        requestBox: RequestBox? = nil,
        baseURL: URL = URL(string: "https://engine.example.test")!
    ) -> HouseholdMachinesClient {
        HouseholdMachinesClient(
            baseURL: baseURL,
            expectedHouseholdID: "hh_example",
            popSigner: signer,
            transport: { request in
                requestBox?.set(request)
                return (
                    body,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": contentType]
                    )!
                )
            }
        )
    }

    func responseData(
        version: UInt64 = 1,
        householdID: String,
        selfMachineID: String?,
        machines: [MachineFixture]
    ) throws -> Data {
        try JSONEncoder().encode(WireResponse(
            version: version,
            householdID: householdID,
            selfMachineID: selfMachineID,
            machines: machines
        ))
    }

    func activeState(householdID: String, endpoint: URL) throws -> ActiveHouseholdState {
        let householdKey = try P256.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x44, count: 32)
        )
        let ownerKey = try P256.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x55, count: 32)
        )
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let ownerPersonID = try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey)
        let personCert = try PersonCert(cbor: HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey,
            householdId: householdID
        ))
        return ActiveHouseholdState(
            householdId: householdID,
            householdName: "Example Household",
            householdPublicKey: householdPublicKey,
            endpoint: endpoint,
            ownerPersonId: ownerPersonID,
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "test-owner-key",
            personCert: personCert,
            pairedAt: Date(timeIntervalSince1970: 1_725_000_000),
            lastSeenAt: nil
        )
    }

    func expectError(
        _ expected: HouseholdMachinesError,
        from client: HouseholdMachinesClient,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await client.fetch()
            Issue.record("Expected \(expected)", sourceLocation: sourceLocation)
        } catch let actual as HouseholdMachinesError {
            #expect(actual == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected HouseholdMachinesError \(expected), got \(error)", sourceLocation: sourceLocation)
        }
    }

}
