import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("MachineReachability")
struct MachineReachabilityTests {
    @Test func machineIDDerivesCanonicalIdentifierFromValidatedMachinePublicKey() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation

        let machineID = try MachineID(authenticatedMachinePublicKey: publicKey)
        let expectedIdentifier = try HouseholdIdentifiers.identifier(
            for: publicKey,
            kind: .machine
        )

        #expect(machineID.machinePublicKey == publicKey)
        #expect(machineID.rawValue == expectedIdentifier)
    }

    @Test func machineIDRejectsPublicKeyOutsideP256() {
        #expect(throws: HouseholdIdentifierError.invalidCompressedP256Point) {
            try MachineID(
                authenticatedMachinePublicKey: Data([0x02]) + Data(repeating: 0xff, count: 32)
            )
        }
    }

    @Test func authorityRequiresReportedSelfMachineIdentifierToMatchAuthenticatedPublicKey() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation

        #expect(throws: MachineReachabilityAuthorityError.selfMachineIdentifierMismatch) {
            try MachineReachabilityAuthority(
                householdID: "hh_example",
                reportedSelfMachineID: "m_not_the_authenticated_key",
                authenticatedSelfMachinePublicKey: publicKey
            )
        }
    }

    @Test func purposeVocabularyIsTheApprovedVersionOneContract() {
        #expect(MachineReachabilityPurpose.allCases == [
            .presence,
            .attach,
            .apnsDispatch,
            .devicePairing,
            .joinStaging,
            .clawInstall,
            .identitySnapshot,
        ])
    }

    @Test func legacyStrategyPreservesStoredEndpointExactly() throws {
        let fixture = try Fixture.make()
        let strategy = LegacyStoredEndpointStrategy(sessionStore: fixture.sessionStore)

        let resolution = strategy.candidates(
            authority: fixture.authority,
            requestedMachineID: fixture.authority.selfMachineID,
            purpose: .joinStaging
        )

        assertLegacyCandidate(
            resolution,
            expectedMachineID: fixture.authority.selfMachineID,
            expectedURL: fixture.endpoint
        )
    }

    @Test func actorDelegatesExactLegacyCandidateWithoutFallbacks() async throws {
        let fixture = try Fixture.make()
        let reachability = MachineReachability(
            authority: fixture.authority,
            sessionStore: fixture.sessionStore
        )

        let resolution = await reachability.candidates(
            machineID: fixture.authority.selfMachineID,
            purpose: .joinStaging
        )

        assertLegacyCandidate(
            resolution,
            expectedMachineID: fixture.authority.selfMachineID,
            expectedURL: fixture.endpoint
        )
    }

    @Test func otherMachineNeverReceivesTheHouseholdLegacyEndpoint() async throws {
        let fixture = try Fixture.make()
        let otherMachineID = try MachineID(
            authenticatedMachinePublicKey: P256.Signing.PrivateKey().publicKey.compressedRepresentation
        )
        let reachability = MachineReachability(
            authority: fixture.authority,
            sessionStore: fixture.sessionStore
        )

        let resolution = await reachability.candidates(
            machineID: otherMachineID,
            purpose: .attach
        )

        #expect(resolution == .unresolved(.requestedMachineIsNotAuthenticatedAuthority))
    }

    @Test func missingAuthorityBindingIsUnresolvedBeforeReadingLegacyState() async throws {
        let fixture = try Fixture.make()
        let reachability = MachineReachability(
            authority: nil,
            sessionStore: HouseholdSessionStore(storage: CorruptStorage())
        )

        let resolution = await reachability.candidates(
            machineID: fixture.authority.selfMachineID,
            purpose: .joinStaging
        )

        #expect(resolution == .unresolved(.missingAuthenticatedAuthorityBinding))
    }

    @Test func missingActiveStateIsUnresolved() async throws {
        let fixture = try Fixture.make(saveState: false)
        let reachability = MachineReachability(
            authority: fixture.authority,
            sessionStore: fixture.sessionStore
        )

        let resolution = await reachability.candidates(
            machineID: fixture.authority.selfMachineID,
            purpose: .identitySnapshot
        )

        #expect(resolution == .unresolved(.noActiveHouseholdState))
    }

    @Test func stateReadFailureIsUnavailable() async throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let machineID = try MachineID(authenticatedMachinePublicKey: publicKey)
        let authority = try MachineReachabilityAuthority(
            householdID: "hh_example",
            reportedSelfMachineID: machineID.rawValue,
            authenticatedSelfMachinePublicKey: publicKey
        )
        let reachability = MachineReachability(
            authority: authority,
            sessionStore: HouseholdSessionStore(storage: CorruptStorage())
        )

        let resolution = await reachability.candidates(
            machineID: machineID,
            purpose: .apnsDispatch
        )

        #expect(resolution == .unavailable(.legacyStateReadFailed))
    }

    @Test func authorityForAnotherHouseholdDoesNotReuseTheLegacySeed() async throws {
        let fixture = try Fixture.make()
        let mismatchedAuthority = try MachineReachabilityAuthority(
            householdID: "hh_other",
            reportedSelfMachineID: fixture.authority.selfMachineID.rawValue,
            authenticatedSelfMachinePublicKey: fixture.authority.selfMachineID.machinePublicKey
        )
        let reachability = MachineReachability(
            authority: mismatchedAuthority,
            sessionStore: fixture.sessionStore
        )

        let resolution = await reachability.candidates(
            machineID: mismatchedAuthority.selfMachineID,
            purpose: .clawInstall
        )

        #expect(resolution == .unresolved(.authorityHouseholdMismatch))
    }

    private func assertLegacyCandidate(
        _ resolution: MachineReachabilityResolution,
        expectedMachineID: MachineID,
        expectedURL: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case let .candidates(primary, fallbacks) = resolution else {
            Issue.record("Expected an exact legacy candidate, got \(resolution)", sourceLocation: sourceLocation)
            return
        }

        #expect(primary.machineID == expectedMachineID, sourceLocation: sourceLocation)
        #expect(primary.baseURL == expectedURL, sourceLocation: sourceLocation)
        #expect(
            primary.baseURL.absoluteString == expectedURL.absoluteString,
            "Legacy strategy must preserve the serialized URL byte-for-byte.",
            sourceLocation: sourceLocation
        )
        #expect(primary.source == .legacyStoredEndpoint, sourceLocation: sourceLocation)
        #expect(fallbacks.isEmpty, sourceLocation: sourceLocation)
    }
}

private extension MachineReachabilityTests {
    struct Fixture {
        let authority: MachineReachabilityAuthority
        let endpoint: URL
        let sessionStore: HouseholdSessionStore

        static func make(saveState: Bool = true) throws -> Self {
            let householdKey = P256.Signing.PrivateKey()
            let ownerKey = P256.Signing.PrivateKey()
            let machineKey = P256.Signing.PrivateKey()
            let householdPublicKey = householdKey.publicKey.compressedRepresentation
            let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
            let machinePublicKey = machineKey.publicKey.compressedRepresentation
            let householdID = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)
            let ownerPersonID = try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey)
            let personCert = try PersonCert(cbor: HouseholdTestFixtures.signedOwnerCert(
                householdPrivateKey: householdKey,
                personPublicKey: ownerPublicKey,
                householdId: householdID
            ))
            let authorityMachineID = try MachineID(
                authenticatedMachinePublicKey: machinePublicKey
            )
            let authority = try MachineReachabilityAuthority(
                householdID: householdID,
                reportedSelfMachineID: authorityMachineID.rawValue,
                authenticatedSelfMachinePublicKey: machinePublicKey
            )
            let endpoint = URL(string: "https://household.example.test:8443/bootstrap")!
            let state = ActiveHouseholdState(
                householdId: householdID,
                householdName: "Example Household",
                householdPublicKey: householdPublicKey,
                endpoint: endpoint,
                ownerPersonId: ownerPersonID,
                ownerPublicKey: ownerPublicKey,
                ownerKeyReference: "owner-key",
                personCert: personCert,
                pairedAt: Date(timeIntervalSince1970: 1_714_972_800),
                lastSeenAt: nil
            )
            let storage = InMemoryStorage()
            let sessionStore = HouseholdSessionStore(storage: storage, account: "machine-reachability")
            if saveState {
                try sessionStore.save(state)
            }

            return Self(
                authority: authority,
                endpoint: endpoint,
                sessionStore: sessionStore
            )
        }
    }

    final class InMemoryStorage: HouseholdSecureStoring, @unchecked Sendable {
        private var values: [String: Data] = [:]

        func save(_ data: Data, account: String) -> Bool {
            values[account] = data
            return true
        }

        func load(account: String) -> Data? {
            values[account]
        }

        func delete(account: String) {
            values.removeValue(forKey: account)
        }
    }

    final class CorruptStorage: HouseholdSecureStoring, @unchecked Sendable {
        func save(_: Data, account _: String) -> Bool { true }

        func load(account _: String) -> Data? {
            Data("not a household session".utf8)
        }

        func delete(account _: String) {}
    }
}
