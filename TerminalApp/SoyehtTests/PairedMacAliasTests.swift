import Testing
import Foundation
import SoyehtCore
@testable import Soyeht

// MARK: - Mac Alias Tests
//
// Locks the contract every UI surface depends on:
//
//   1. `PairedMac.displayName` returns alias when set, hostname otherwise.
//   2. `PairedMacsStore.setAlias` enforces non-empty + length + char rules.
//   3. Duplicate aliases are rejected case-insensitively.
//   4. The same Mac re-setting its own alias is NOT a duplicate.
//   5. `paired(forServer:)` matches by hostname and gates on `.engine` kind.
//
// If a future change makes these tests fail, that means the canonical
// behaviour of "alias-first display name + dedupe" was broken. Fix the code,
// not the tests.

@MainActor
struct PairedMacAliasTests {

    // MARK: - Fixtures

    private func makeStore() -> (PairedMacsStore, () -> Void) {
        let defaultsName = "com.soyeht.tests.alias.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let keychain = KeychainHelper(service: "com.soyeht.tests.alias.\(UUID().uuidString)")
        let store = PairedMacsStore(defaults: defaults, keychain: keychain)
        let teardown = {
            defaults.removePersistentDomain(forName: defaultsName)
            keychain.deleteAll()
        }
        return (store, teardown)
    }

    private func seedMac(
        _ store: PairedMacsStore,
        macID: UUID = UUID(),
        name: String = "mac-alpha",
        host: String? = nil,
        engineMachineId: String? = nil
    ) -> UUID {
        store.upsertMac(macID: macID, name: name, host: host, engineMachineId: engineMachineId)
        return macID
    }

    // MARK: - engineMachineId persistence

    @Test func legacyPairedMacPayloadWithoutEngineMachineIdDecodesNil() throws {
        let json = """
        {
          "macID": "AAAAAAAA-0000-0000-0000-000000000101",
          "name": "machine-alpha",
          "alias": null,
          "lastHost": "mac-alpha.test",
          "presencePort": 7000,
          "attachPort": 7001,
          "firstPairedAt": "2026-01-01T00:00:00Z",
          "lastSeenAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.pairingMobile.decode(PairedMac.self, from: json)

        #expect(decoded.engineMachineId == nil)
    }

    @Test func upsertMacStoresEngineMachineIdAndDoesNotClearWithNilIncomingValue() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macID = UUID()

        store.upsertMac(
            macID: macID,
            name: "machine-alpha",
            host: "mac-alpha.test",
            engineMachineId: "machine-alpha"
        )
        store.upsertMac(macID: macID, name: "machine-alpha", host: "mac-alpha.test")

        #expect(store.macs.first(where: { $0.macID == macID })?.engineMachineId == "machine-alpha")
    }

    @Test func setEngineMachineIdIsIdempotent() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macID = seedMac(store, name: "machine-alpha", host: "mac-alpha.test")

        #expect(store.setEngineMachineId(macID: macID, engineMachineId: " machine-alpha ") == true)
        #expect(store.macs.first(where: { $0.macID == macID })?.engineMachineId == "machine-alpha")
        #expect(store.setEngineMachineId(macID: macID, engineMachineId: "machine-alpha") == false)
        #expect(store.setEngineMachineId(macID: macID, engineMachineId: "   ") == false)
    }

    @Test func pairedMacToServerEmitsEngineMachineId() {
        let mac = PairedMac(
            macID: UUID(),
            name: "machine-alpha",
            lastHost: "mac-alpha.test",
            engineMachineId: "machine-alpha",
            firstPairedAt: Date(),
            lastSeenAt: Date()
        )

        #expect(mac.toServer().engineMachineId == "machine-alpha")
    }

    // MARK: - displayName

    @Test func displayNamePrefersAliasOverHostname() {
        let mac = PairedMac(
            macID: UUID(),
            name: "mac-alpha",
            alias: "Team's Studio",
            firstPairedAt: Date(),
            lastSeenAt: Date()
        )
        #expect(mac.displayName == "Team's Studio")
    }

    @Test func displayNameFallsBackToHostnameWhenAliasNil() {
        let mac = PairedMac(
            macID: UUID(),
            name: "mac-alpha",
            firstPairedAt: Date(),
            lastSeenAt: Date()
        )
        #expect(mac.displayName == "mac-alpha")
        #expect(mac.needsAlias == true)
    }

    @Test func displayNameTreatsWhitespaceAliasAsEmpty() {
        let mac = PairedMac(
            macID: UUID(),
            name: "mac-alpha",
            alias: "   ",
            firstPairedAt: Date(),
            lastSeenAt: Date()
        )
        #expect(mac.displayName == "mac-alpha")
        #expect(mac.needsAlias == true)
    }

    // MARK: - Validation

    @Test func validatorRejectsEmpty() {
        #expect(MacAliasValidator.validate("") == .failure(.empty))
        #expect(MacAliasValidator.validate("   ") == .failure(.empty))
    }

    @Test func validatorRejectsOversize() {
        let big = String(repeating: "a", count: MacAliasRules.maxLength + 1)
        #expect(MacAliasValidator.validate(big) == .failure(.tooLong))
    }

    @Test func validatorRejectsForbiddenChars() {
        #expect(MacAliasValidator.validate("bad/name") == .failure(.forbiddenCharacters))
        #expect(MacAliasValidator.validate("colon:name") == .failure(.forbiddenCharacters))
    }

    @Test func validatorAcceptsAccentsApostropheAndSpaces() {
        #expect(MacAliasValidator.validate("Team's Home") == .success("Team's Home"))
        #expect(MacAliasValidator.validate("Café Studio") == .success("Café Studio"))
    }

    @Test func validatorTrimsLeadingTrailingWhitespace() {
        #expect(MacAliasValidator.validate("  Studio  ") == .success("Studio"))
    }

    // MARK: - setAlias

    @Test func setAliasSucceedsOnFreshMac() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let id = seedMac(store)

        #expect(store.setAlias(macID: id, alias: "Team's Studio") == .success)
        #expect(store.macs.first?.alias == "Team's Studio")
        #expect(store.macs.first?.displayName == "Team's Studio")
    }

    @Test func setAliasReturnsUnknownMacWhenIDMissing() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        let result = store.setAlias(macID: UUID(), alias: "Whatever")
        #expect(result == .unknownMac)
    }

    @Test func setAliasReturnsInvalidOnBadInput() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let id = seedMac(store)

        #expect(store.setAlias(macID: id, alias: "") == .invalid(.empty))
        #expect(store.setAlias(macID: id, alias: "bad/path") == .invalid(.forbiddenCharacters))
    }

    @Test func setAliasRejectsDuplicateOnOtherMac() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macA = seedMac(store, name: "mac-alpha")
        let macB = seedMac(store, name: "mac-beta")
        #expect(store.setAlias(macID: macA, alias: "Home Base") == .success)

        let result = store.setAlias(macID: macB, alias: "Home Base")
        #expect(result == .duplicate(conflictingMacID: macA))
        #expect(store.macs.first(where: { $0.macID == macB })?.alias == nil)
    }

    @Test func setAliasRejectsDuplicateCaseInsensitively() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macA = seedMac(store, name: "mac-alpha")
        let macB = seedMac(store, name: "mac-beta")
        #expect(store.setAlias(macID: macA, alias: "Studio") == .success)

        // Different case must still be detected as duplicate.
        #expect(store.setAlias(macID: macB, alias: "STUDIO") == .duplicate(conflictingMacID: macA))
        #expect(store.setAlias(macID: macB, alias: "studio") == .duplicate(conflictingMacID: macA))
    }

    @Test func setAliasAllowsSameMacResettingToSameValue() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let id = seedMac(store)
        #expect(store.setAlias(macID: id, alias: "Studio") == .success)
        // Re-setting the same alias on the SAME mac should not be a duplicate.
        #expect(store.setAlias(macID: id, alias: "Studio") == .success)
    }

    // MARK: - default alias

    @Test func setDefaultAliasIfNeededUsesMacNameWhenUnnamed() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let id = seedMac(store, name: "mac-alpha")

        #expect(store.setDefaultAliasIfNeeded(macID: id, suggestedAlias: "mac-alpha") == .success)
        #expect(store.macs.first(where: { $0.macID == id })?.alias == "mac-alpha")
        #expect(store.macs.first(where: { $0.macID == id })?.needsAlias == false)
    }

    @Test func setDefaultAliasIfNeededPreservesUserAlias() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let id = seedMac(store, name: "mac-alpha")
        #expect(store.setAlias(macID: id, alias: "Studio") == .success)

        #expect(store.setDefaultAliasIfNeeded(macID: id, suggestedAlias: "mac-alpha") == .success)
        #expect(store.macs.first(where: { $0.macID == id })?.alias == "Studio")
    }

    @Test func setDefaultAliasIfNeededCreatesUniqueFallback() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let first = seedMac(store, name: "mac-alpha")
        let second = seedMac(store, name: "mac-beta")
        #expect(store.setDefaultAliasIfNeeded(macID: first, suggestedAlias: "mac-alpha") == .success)

        #expect(store.setDefaultAliasIfNeeded(macID: second, suggestedAlias: "mac-alpha") == .success)
        #expect(store.macs.first(where: { $0.macID == second })?.alias == "mac-alpha 2")
    }

    // MARK: - paired(forServer:)

    @Test func pairedForServerMatchesHostForEngineKind() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macID = seedMac(store, name: "mac-alpha", host: "192.0.2.10")

        let server = PairedServer(
            id: "srv-1",
            host: "192.0.2.10",
            name: "mac-alpha",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )

        let mac = store.paired(forServer: server)
        #expect(mac?.macID == macID)
    }

    @Test func pairedForServerReturnsNilForAdminHost() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        _ = seedMac(store, host: "192.0.2.10")

        let server = PairedServer(
            id: "srv-admin",
            host: "192.0.2.10",
            name: "linux-alpha",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )

        #expect(store.paired(forServer: server) == nil)
    }

    @Test func displayNameForServerPrefersMacAlias() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macID = seedMac(store, name: "mac-alpha", host: "192.0.2.10")
        #expect(store.setAlias(macID: macID, alias: "Team's Studio") == .success)

        let server = PairedServer(
            id: "srv-1",
            host: "192.0.2.10",
            name: "mac-alpha",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )

        #expect(store.displayName(forServer: server) == "Team's Studio")
    }
}
