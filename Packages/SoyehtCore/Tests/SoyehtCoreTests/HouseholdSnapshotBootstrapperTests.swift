import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdSnapshotBootstrapper")
struct HouseholdSnapshotBootstrapperTests {
    private static let now = Date(timeIntervalSince1970: 1_715_000_000)

    @Test func validSnapshotSeedsCRLAndMembershipAtomically() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x22, hostname: "studio.local")
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [cert.value],
            revocations: [],
            cursor: 42
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.valid")
        let members = HouseholdMembershipStore()
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        let result = try await bootstrapper.bootstrap()

        #expect(result.cursor == 42)
        #expect(result.insertedRevocationCount == 0)
        #expect(result.memberCount == 1)
        #expect(result.skippedRevokedMachineCount == 0)
        #expect(await store.currentSnapshotCursor() == 42)
        #expect(await store.snapshotEntries().isEmpty)
        let snapshot = await members.snapshot()
        #expect(snapshot.map(\.machineId) == [cert.machineId])
        #expect(snapshot.first?.hostname == "studio.local")
    }

    @Test func tamperedSnapshotSignatureAbortsWithoutPartialState() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x22)
        let revoked = try Self.revocationValue(context: context, subjectId: "m_revoked")
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [cert.value],
            revocations: [revoked.value],
            cursor: 9,
            tamperAfterSigning: { body in
                body["issued_at"] = .unsigned(1)
            }
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.tampered")
        let members = HouseholdMembershipStore()
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        do {
            _ = try await bootstrapper.bootstrap()
            Issue.record("Expected invalid snapshot signature")
        } catch let error as MachineJoinError {
            #expect(error == .certValidationFailed(reason: .signatureInvalid))
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(await store.snapshotEntries().isEmpty)
        #expect(await store.currentSnapshotCursor() == nil)
        #expect(await members.snapshot().isEmpty)
    }

    @Test func emptyCRLSnapshotCanReplaceExistingMembers() async throws {
        let context = try Self.context()
        let oldMember = HouseholdMember(
            machineId: "m_old",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            hostname: "old.local",
            platform: .macos,
            joinedAt: Self.now
        )
        let members = HouseholdMembershipStore(initial: [oldMember])
        let first = try Self.machineCert(context: context, seed: 0x22, hostname: "alpha.local")
        let second = try Self.machineCert(context: context, seed: 0x33, hostname: "beta.local")
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [first.value, second.value],
            revocations: [],
            cursor: 11
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.empty-crl")
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        let result = try await bootstrapper.bootstrap()

        #expect(result.memberCount == 2)
        #expect(await store.snapshotEntries().isEmpty)
        #expect(await members.snapshot().map(\.machineId) == [first.machineId, second.machineId].sorted())
        #expect(await members.contains("m_old") == false)
    }

    @Test func populatedCRLSeedsStoreAndExcludesRevokedMachineFromMembership() async throws {
        let context = try Self.context()
        let active = try Self.machineCert(context: context, seed: 0x22, hostname: "active.local")
        let revokedMachine = try Self.machineCert(context: context, seed: 0x33, hostname: "revoked.local")
        let revocation = try Self.revocationValue(
            context: context,
            subjectId: revokedMachine.machineId,
            reason: "compromise"
        )
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [active.value, revokedMachine.value],
            revocations: [revocation.value],
            cursor: 12
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.populated-crl")
        let members = HouseholdMembershipStore()
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        let result = try await bootstrapper.bootstrap()

        #expect(result.insertedRevocationCount == 1)
        #expect(result.memberCount == 1)
        #expect(result.skippedRevokedMachineCount == 1)
        #expect(await store.contains(revokedMachine.machineId))
        #expect(await members.snapshot().map(\.machineId) == [active.machineId])
    }

    @Test func historicalSnapshotCRLPreRejectsLaterMachineAddedDelta() async throws {
        let context = try Self.context()
        let revokedMachine = try Self.machineCert(
            context: context,
            seed: 0x44,
            joinedAt: Self.now.addingTimeInterval(-31 * 24 * 60 * 60)
        )
        let thirtyDaysAgo = Self.now.addingTimeInterval(-30 * 24 * 60 * 60)
        let revocation = try Self.revocationValue(
            context: context,
            subjectId: revokedMachine.machineId,
            revokedAt: thirtyDaysAgo,
            reason: "retired"
        )
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [],
            revocations: [revocation.value],
            cursor: 99
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.historical-crl")
        let members = HouseholdMembershipStore()
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        _ = try await bootstrapper.bootstrap()

        #expect(await store.contains(revokedMachine.machineId))
        let cert = try MachineCert(cbor: revokedMachine.cbor)
        do {
            try await MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: context.householdId,
                householdPublicKey: context.householdPublicKey,
                crl: store,
                now: Self.now
            )
            Issue.record("Expected the snapshot CRL to pre-reject the later delta")
        } catch MachineCertError.revoked {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(await members.snapshot().isEmpty)
    }

    /// `as_of_vc` is intentionally rejected at the allowlist layer in
    /// Phase 3 — see `knownBodyKeys` in `HouseholdSnapshotBootstrapper`
    /// for the rationale. Even though the underlying issue is the same
    /// as `snapshotWithoutAsOfCursorIsRejectedBeforeStateMutation` (no
    /// usable resume cursor), the rejection now happens *earlier* (on
    /// the unknown-key check) and the post-rejection invariant — empty
    /// CRL, empty membership, no cursor recorded — still holds.
    @Test func snapshotWithAsOfVCFieldIsRejectedBeforeStateMutation() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x55, hostname: "vc-only.local")
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [cert.value],
            revocations: [],
            cursorOverride: nil,
            extraBodyFields: ["as_of_vc": .bytes(Data([0x00, 0x01, 0x02]))]
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.vc-only")
        let members = HouseholdMembershipStore()
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        do {
            _ = try await bootstrapper.bootstrap()
            Issue.record("Expected an as_of_vc-bearing snapshot to be rejected")
        } catch let error as MachineJoinError {
            #expect(error == .protocolViolation(detail: .unexpectedResponseShape))
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(await store.snapshotEntries().isEmpty)
        #expect(await store.currentSnapshotCursor() == nil)
        #expect(await members.snapshot().isEmpty)
    }

    @Test func snapshotWithoutAsOfCursorIsRejectedBeforeStateMutation() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x77, hostname: "no-cursor.local")
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [cert.value],
            revocations: [],
            cursorOverride: nil,
            extraBodyFields: [:]
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.no-cursor")
        let members = HouseholdMembershipStore()
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        do {
            _ = try await bootstrapper.bootstrap()
            Issue.record("Expected a snapshot missing as_of_cursor to be rejected")
        } catch let error as MachineJoinError {
            #expect(error == .protocolViolation(detail: .unexpectedResponseShape))
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(await store.snapshotEntries().isEmpty)
        #expect(await store.currentSnapshotCursor() == nil)
        #expect(await members.snapshot().isEmpty)
    }

    @Test func snapshotWithBytesCursorIsRejectedBeforeStateMutation() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x66)
        let envelope = try Self.snapshotEnvelope(
            context: context,
            machines: [cert.value],
            revocations: [],
            cursorOverride: .bytes(Data([0xFE, 0xED, 0xFA, 0xCE])),
            extraBodyFields: [:]
        )
        let store = try CRLStore(storage: InMemoryHouseholdStorage(), account: "snapshot.bytes-cursor")
        let members = HouseholdMembershipStore()
        let bootstrapper = HouseholdSnapshotBootstrapper(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: store,
            membershipStore: members,
            fetchSnapshot: { envelope },
            nowProvider: { Self.now }
        )

        do {
            _ = try await bootstrapper.bootstrap()
            Issue.record("Expected a bytes-encoded cursor to be rejected")
        } catch let error as MachineJoinError {
            #expect(error == .protocolViolation(detail: .unexpectedResponseShape))
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(await store.snapshotEntries().isEmpty)
        #expect(await store.currentSnapshotCursor() == nil)
        #expect(await members.snapshot().isEmpty)
    }

    private struct Context {
        let householdPrivateKey: P256.Signing.PrivateKey
        let householdPublicKey: Data
        let householdId: String
    }

    private struct MachineCertFixture {
        let cbor: Data
        let value: HouseholdCBORValue
        let machineId: String
    }

    private struct RevocationFixture {
        let value: HouseholdCBORValue
    }

    private static func context(seed: UInt8 = 0x11) throws -> Context {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let publicKey = key.publicKey.compressedRepresentation
        return Context(
            householdPrivateKey: key,
            householdPublicKey: publicKey,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: publicKey)
        )
    }

    private static func machineCert(
        context: Context,
        seed: UInt8,
        hostname: String = "studio.local",
        joinedAt: Date? = nil
    ) throws -> MachineCertFixture {
        let machinePublicKey = HouseholdTestFixtures.publicKey(byte: seed)
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: context.householdPrivateKey,
            machinePublicKey: machinePublicKey,
            hostname: hostname,
            joinedAt: joinedAt ?? Self.now.addingTimeInterval(-60)
        )
        let cert = try MachineCert(cbor: cbor)
        return MachineCertFixture(
            cbor: cbor,
            value: try HouseholdCBOR.decode(cbor),
            machineId: cert.machineId
        )
    }

    private static func revocationValue(
        context: Context,
        subjectId: String,
        revokedAt: Date? = nil,
        reason: String = "compromise",
        cascade: RevocationEntry.Cascade = .selfOnly
    ) throws -> RevocationFixture {
        var map: [String: HouseholdCBORValue] = [
            "cascade": .text(cascade.rawValue),
            "reason": .text(reason),
            "revoked_at": .unsigned(UInt64((revokedAt ?? Self.now.addingTimeInterval(-120)).timeIntervalSince1970)),
            "subject_id": .text(subjectId),
        ]
        let signingBytes = HouseholdCBOR.encode(.map(map))
        map["signature"] = .bytes(
            try context.householdPrivateKey.signature(for: signingBytes).rawRepresentation
        )
        return RevocationFixture(value: .map(map))
    }

    private static func snapshotEnvelope(
        context: Context,
        machines: [HouseholdCBORValue],
        revocations: [HouseholdCBORValue],
        cursor: UInt64,
        tamperAfterSigning: ((inout [String: HouseholdCBORValue]) -> Void)? = nil
    ) throws -> Data {
        try snapshotEnvelope(
            context: context,
            machines: machines,
            revocations: revocations,
            cursorOverride: .unsigned(cursor),
            extraBodyFields: [:],
            tamperAfterSigning: tamperAfterSigning
        )
    }

    /// Builder used by the negative-path tests that exercise unsupported
    /// cursor encodings. `cursorOverride == nil` omits `as_of_cursor`
    /// entirely; otherwise the override value is written verbatim so a test
    /// can ship `.bytes(...)`, `.text(...)`, etc.
    private static func snapshotEnvelope(
        context: Context,
        machines: [HouseholdCBORValue],
        revocations: [HouseholdCBORValue],
        cursorOverride: HouseholdCBORValue?,
        extraBodyFields: [String: HouseholdCBORValue],
        tamperAfterSigning: ((inout [String: HouseholdCBORValue]) -> Void)? = nil
    ) throws -> Data {
        var body: [String: HouseholdCBORValue] = [
            "crl": .array(revocations),
            "head_event_hash": .bytes(Data(repeating: 0xAB, count: 32)),
            "hh_id": .text(context.householdId),
            "issued_at": .unsigned(UInt64(Self.now.timeIntervalSince1970)),
            "machines": .array(machines),
            "v": .unsigned(1),
        ]
        if let cursorOverride {
            body["as_of_cursor"] = cursorOverride
        }
        for (key, value) in extraBodyFields {
            body[key] = value
        }
        let bodyBytes = HouseholdCBOR.encode(.map(body))
        let signature = try context.householdPrivateKey.signature(for: bodyBytes).rawRepresentation
        tamperAfterSigning?(&body)
        return HouseholdCBOR.encode(.map([
            "signature": .bytes(signature),
            "snapshot": .map(body),
            "v": .unsigned(1),
        ]))
    }
}
