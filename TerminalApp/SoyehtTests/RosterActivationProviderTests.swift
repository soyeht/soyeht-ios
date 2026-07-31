import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// Contract tests for `RosterActivationProvider`.
///
/// The provider is the only place the roster acquires a base URL, and it must
/// do so exclusively through `MachineReachability`. Every failure mode has to
/// produce `nil` — never a synthesized URL, never a throw that could reach the
/// activation's error path.
final class RosterActivationProviderTests: XCTestCase {
    // MARK: - Fixtures

    private static func machinePublicKey(byte: UInt8) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
            .publicKey.compressedRepresentation
    }

    private static func authority(
        householdID: String, keyByte: UInt8
    ) throws -> MachineReachabilityAuthority {
        let publicKey = try machinePublicKey(byte: keyByte)
        let machineID = try MachineID(authenticatedMachinePublicKey: publicKey)
        return try MachineReachabilityAuthority(
            householdID: householdID,
            reportedSelfMachineID: machineID.rawValue,
            authenticatedSelfMachinePublicKey: publicKey
        )
    }

    private static func snapshot(
        householdID: String, authority: MachineReachabilityAuthority
    ) -> HouseholdMachinesSnapshot {
        let machine = HouseholdMachine(
            machineID: authority.selfMachineID,
            hostLabel: "mac-alpha",
            platform: "macos",
            isSelf: true,
            capabilities: [],
            joinedAt: 1_000
        )
        return HouseholdMachinesSnapshot(
            householdID: householdID,
            selfMachine: machine,
            machines: [machine],
            reachabilityAuthority: authority
        )
    }

    private static func popSigner(personId: String = "p_test") -> HouseholdPoPSigner {
        HouseholdPoPSigner(
            ownerIdentity: ProviderFakeOwnerIdentity(
                personId: personId,
                publicKey: Data(repeating: 0x02, count: 33),
                keyReference: "ref"
            ),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private static func household(id: String = "hh_provider") -> ActiveHouseholdState {
        let ownerKey = P256.Signing.PrivateKey()
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let householdPublicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let cert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: id,
            personId: "p_test",
            personPublicKey: ownerPublicKey,
            displayName: "Owner",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: "hh:\(id)",
            signature: Data(repeating: 0x11, count: 64)
        )
        return ActiveHouseholdState(
            householdId: id,
            householdName: "Provider",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://127.0.0.1:1")!,
            ownerPersonId: "p_test",
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "ref",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil
        )
    }

    private func makeActivator(
        householdID: String = "hh_provider",
        bootstrap: @escaping RosterActivationProvider.AuthorityBootstrap,
        resolve: @escaping RosterActivationProvider.ResolveCandidates
    ) async -> (any RosterEvidenceActivating)? {
        let provider = RosterActivationProvider(
            bootstrapAuthority: bootstrap,
            resolveCandidates: resolve
        )
        return await provider.makeActivator(
            household: Self.household(id: householdID),
            popSigner: Self.popSigner(),
            session: .shared,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private static func resolved(_ authority: MachineReachabilityAuthority) -> MachineReachabilityResolution {
        .candidates(
            primary: MachineReachabilityCandidate(
                machineID: authority.selfMachineID,
                baseURL: URL(string: "http://192.0.2.10:8101")!,
                source: .legacyStoredEndpoint
            ),
            fallbacks: []
        )
    }

    // MARK: - Happy path

    func testResolvedCandidateProducesActivator() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x11)
        let activator = await makeActivator(
            bootstrap: { _ in Self.snapshot(householdID: "hh_provider", authority: authority) },
            resolve: { _, _ in Self.resolved(authority) }
        )
        XCTAssertNotNil(activator)
    }

    /// The route must be requested for the authenticated self machine, never for
    /// an arbitrary or caller-supplied identity.
    func testResolutionIsRequestedForAuthenticatedSelfMachine() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x12)
        let box = RequestedMachineBox()
        _ = await makeActivator(
            bootstrap: { _ in Self.snapshot(householdID: "hh_provider", authority: authority) },
            resolve: { requestedAuthority, requestedMachine in
                box.record(
                    authorityHousehold: requestedAuthority.householdID,
                    machineID: requestedMachine.rawValue
                )
                return Self.resolved(authority)
            }
        )
        XCTAssertEqual(box.machineID, authority.selfMachineID.rawValue)
        XCTAssertEqual(box.authorityHousehold, "hh_provider")
    }

    /// One authority bootstrap and one resolution per activation — no retry.
    func testBootstrapAndResolveHappenExactlyOnce() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x13)
        let counter = ProviderCallCounter()
        _ = await makeActivator(
            bootstrap: { _ in
                counter.bump("bootstrap")
                return Self.snapshot(householdID: "hh_provider", authority: authority)
            },
            resolve: { _, _ in
                counter.bump("resolve")
                return Self.resolved(authority)
            }
        )
        XCTAssertEqual(counter.count("bootstrap"), 1)
        XCTAssertEqual(counter.count("resolve"), 1)
    }

    /// The signer handed to the bootstrap must be the same one the caller
    /// supplied, so route authentication and roster calls cannot diverge.
    func testBootstrapReceivesCallerSuppliedSigner() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x14)
        let box = SignerBox()
        _ = await makeActivator(
            bootstrap: { signer in
                box.header = try? signer.authorization(
                    method: "GET", pathAndQuery: "/probe", body: Data()
                ).authorizationHeader
                return Self.snapshot(householdID: "hh_provider", authority: authority)
            },
            resolve: { _, _ in Self.resolved(authority) }
        )
        let header = try XCTUnwrap(box.header)
        XCTAssertTrue(
            header.contains("p_test"),
            "Bootstrap must sign with the caller's identity; got \(header)"
        )
    }

    // MARK: - Every failure yields nil, never a URL

    func testBootstrapFailureYieldsNil() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x15)
        let activator = await makeActivator(
            bootstrap: { _ in throw MachineReachabilityAuthorityBootstrapError.noActiveHouseholdState },
            resolve: { _, _ in Self.resolved(authority) }
        )
        XCTAssertNil(activator)
    }

    func testSnapshotHouseholdMismatchYieldsNil() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x16)
        let activator = await makeActivator(
            bootstrap: { _ in Self.snapshot(householdID: "hh_someoneelse", authority: authority) },
            resolve: { _, _ in Self.resolved(authority) }
        )
        XCTAssertNil(activator)
    }

    func testAuthorityHouseholdMismatchYieldsNil() async throws {
        let foreign = try Self.authority(householdID: "hh_foreign", keyByte: 0x17)
        let activator = await makeActivator(
            bootstrap: { _ in Self.snapshot(householdID: "hh_provider", authority: foreign) },
            resolve: { _, _ in Self.resolved(foreign) }
        )
        XCTAssertNil(activator)
    }

    func testUnresolvedResolutionYieldsNil() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x18)
        let activator = await makeActivator(
            bootstrap: { _ in Self.snapshot(householdID: "hh_provider", authority: authority) },
            resolve: { _, _ in .unresolved(.missingAuthenticatedAuthorityBinding) }
        )
        XCTAssertNil(activator)
    }

    func testUnavailableResolutionYieldsNil() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x19)
        let activator = await makeActivator(
            bootstrap: { _ in Self.snapshot(householdID: "hh_provider", authority: authority) },
            resolve: { _, _ in .unavailable(.legacyStateReadFailed) }
        )
        XCTAssertNil(activator)
    }

    /// A candidate scoped to a different machine than the authenticated self
    /// machine must be refused rather than used as a route.
    func testCandidateForForeignMachineYieldsNil() async throws {
        let authority = try Self.authority(householdID: "hh_provider", keyByte: 0x1A)
        let otherKey = try Self.machinePublicKey(byte: 0x1B)
        let otherMachine = try MachineID(authenticatedMachinePublicKey: otherKey)
        let activator = await makeActivator(
            bootstrap: { _ in Self.snapshot(householdID: "hh_provider", authority: authority) },
            resolve: { _, _ in
                .candidates(
                    primary: MachineReachabilityCandidate(
                        machineID: otherMachine,
                        baseURL: URL(string: "http://198.51.100.10:8101")!,
                        source: .legacyStoredEndpoint
                    ),
                    fallbacks: []
                )
            }
        )
        XCTAssertNil(activator)
    }
}

// MARK: - Fakes

private final class RequestedMachineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMachineID: String?
    private var recordedHousehold: String?

    func record(authorityHousehold: String, machineID: String) {
        lock.lock(); defer { lock.unlock() }
        recordedHousehold = authorityHousehold
        recordedMachineID = machineID
    }

    var machineID: String? {
        lock.lock(); defer { lock.unlock() }
        return recordedMachineID
    }

    var authorityHousehold: String? {
        lock.lock(); defer { lock.unlock() }
        return recordedHousehold
    }
}

private final class ProviderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func bump(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key] ?? 0
    }
}

private final class SignerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var header: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private struct ProviderFakeOwnerIdentity: OwnerIdentitySigning {
    let personId: String
    let publicKey: Data
    let keyReference: String

    func sign(_ payload: Data) throws -> Data {
        Data(repeating: 0x03, count: 64)
    }
}
