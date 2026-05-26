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
        name: String = "macStudio",
        host: String? = nil
    ) -> UUID {
        store.upsertMac(macID: macID, name: name, host: host)
        return macID
    }

    // MARK: - displayName

    @Test func displayNamePrefersAliasOverHostname() {
        let mac = PairedMac(
            macID: UUID(),
            name: "macStudio",
            alias: "Caio's Studio",
            firstPairedAt: Date(),
            lastSeenAt: Date()
        )
        #expect(mac.displayName == "Caio's Studio")
    }

    @Test func displayNameFallsBackToHostnameWhenAliasNil() {
        let mac = PairedMac(
            macID: UUID(),
            name: "macStudio",
            firstPairedAt: Date(),
            lastSeenAt: Date()
        )
        #expect(mac.displayName == "macStudio")
        #expect(mac.needsAlias == true)
    }

    @Test func displayNameTreatsWhitespaceAliasAsEmpty() {
        let mac = PairedMac(
            macID: UUID(),
            name: "macStudio",
            alias: "   ",
            firstPairedAt: Date(),
            lastSeenAt: Date()
        )
        #expect(mac.displayName == "macStudio")
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
        #expect(MacAliasValidator.validate("Caio's Home") == .success("Caio's Home"))
        #expect(MacAliasValidator.validate("Caío Studio") == .success("Caío Studio"))
    }

    @Test func validatorTrimsLeadingTrailingWhitespace() {
        #expect(MacAliasValidator.validate("  Studio  ") == .success("Studio"))
    }

    // MARK: - setAlias

    @Test func setAliasSucceedsOnFreshMac() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let id = seedMac(store)

        #expect(store.setAlias(macID: id, alias: "Caio's Studio") == .success)
        #expect(store.macs.first?.alias == "Caio's Studio")
        #expect(store.macs.first?.displayName == "Caio's Studio")
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
        let macA = seedMac(store, name: "macStudio")
        let macB = seedMac(store, name: "macMini")
        #expect(store.setAlias(macID: macA, alias: "Home Base") == .success)

        let result = store.setAlias(macID: macB, alias: "Home Base")
        #expect(result == .duplicate(conflictingMacID: macA))
        #expect(store.macs.first(where: { $0.macID == macB })?.alias == nil)
    }

    @Test func setAliasRejectsDuplicateCaseInsensitively() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macA = seedMac(store, name: "macStudio")
        let macB = seedMac(store, name: "macMini")
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

    // MARK: - paired(forServer:)

    @Test func pairedForServerMatchesHostForEngineKind() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macID = seedMac(store, name: "macStudio", host: "10.0.0.42")

        let server = PairedServer(
            id: "srv-1",
            host: "10.0.0.42",
            name: "macStudio",
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
        _ = seedMac(store, host: "10.0.0.42")

        let server = PairedServer(
            id: "srv-admin",
            host: "10.0.0.42",
            name: "linux-box",
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
        let macID = seedMac(store, name: "macStudio", host: "10.0.0.42")
        #expect(store.setAlias(macID: macID, alias: "Caio's Studio") == .success)

        let server = PairedServer(
            id: "srv-1",
            host: "10.0.0.42",
            name: "macStudio",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )

        #expect(store.displayName(forServer: server) == "Caio's Studio")
    }
}
