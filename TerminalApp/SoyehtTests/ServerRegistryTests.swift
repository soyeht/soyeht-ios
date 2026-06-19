import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// PR-2 contract: `ServerRegistry` is the sole public surface for
/// listing, counting, renaming, and removing paired servers. The
/// kind-aware dispatch (Mac → `PairedMacsStore`, Linux →
/// `SessionStore`) lives inside the registry; views never branch on
/// `server.kind` for mutation paths.
///
/// The registry's `installLegacyMirror()` is wired in production by
/// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. The
/// SoyehtTests target hosts inside `Soyeht.app`, so the same
/// `AppDelegate` runs before any test and the mirror is live. The
/// mirror callback hops via `Task { @MainActor in
/// refreshFromLegacyStores() }`. In a single-test run a single
/// `await Task.yield()` is enough to drain that task, but in the
/// full-suite the main-actor queue carries enqueued work from many
/// other tests; relying on `Task.yield()` to reach our refresh
/// becomes order-dependent. These tests instead call
/// `registry.refreshFromLegacyStores()` synchronously after every
/// legacy mutation — the same function the production mirror runs,
/// just without the Task hop. The kind-aware dispatch contract
/// (the actual subject under test) is exercised end-to-end; the
/// async mirror plumbing is covered by Bug 1's existing tests.
///
/// Tests scope themselves with unique ids/hosts so parallel /
/// re-entrant runs don't trip on each other, and tear down every
/// entry they create.
@MainActor
final class ServerRegistryTests: XCTestCase {
    private let registry = ServerRegistry.shared
    private let pairedMacs = PairedMacsStore.shared
    private let sessionStore = SessionStore.shared

    private var createdMacIDs: [UUID] = []
    private var createdSessionServerIDs: [String] = []

    override func tearDown() async throws {
        for id in createdMacIDs {
            pairedMacs.remove(macID: id)
        }
        for id in createdSessionServerIDs {
            sessionStore.removeServer(id: id)
        }
        createdMacIDs.removeAll()
        createdSessionServerIDs.removeAll()
        // Drain the mirror so the next test starts from a registry
        // that already reflects the cleanup.
        registry.refreshFromLegacyStores()
        try await super.tearDown()
    }

    // MARK: - linuxServers / macs / count

    func testMacs_macsOnly() async throws {
        let macID = try await seedMac(host: "srt-host-macs-only.test", name: "alpha")

        let macs = registry.macs
        XCTAssertTrue(macs.contains(where: { $0.id == macID.uuidString }))
        XCTAssertTrue(macs.allSatisfy { $0.kind == .mac },
            ".macs must filter to kind == .mac only"
        )
    }

    func testLinuxServers_linuxOnly() async throws {
        let linuxID = try await seedLinux(host: "srt-host-linux-only.test", name: "linux-alpha")

        let linux = registry.linuxServers
        XCTAssertTrue(linux.contains(where: { $0.id == linuxID }))
        XCTAssertTrue(linux.allSatisfy { $0.kind == .linux },
            ".linuxServers must filter to kind == .linux only"
        )
    }

    func testCount_matchesServersCount() async throws {
        let baseline = registry.count
        _ = try await seedMac(host: "srt-host-count-mac.test", name: "count-mac")
        _ = try await seedLinux(host: "srt-host-count-linux.test", name: "count-linux")

        XCTAssertEqual(registry.count, registry.servers.count)
        XCTAssertGreaterThanOrEqual(registry.count, baseline + 2)
    }

    // MARK: - pairedMac helper

    func testPairedMac_returnsLegacyValueForMacKind() async throws {
        let macID = try await seedMac(host: "srt-host-pm-mac.test", name: "pm-mac")

        let paired = registry.pairedMac(for: macID.uuidString)
        XCTAssertNotNil(paired)
        XCTAssertEqual(paired?.macID, macID)
    }

    func testPairedMac_returnsNilForLinuxKind() async throws {
        let linuxID = try await seedLinux(host: "srt-host-pm-linux.test", name: "pm-linux")

        XCTAssertNil(registry.pairedMac(for: linuxID),
            "Linux servers don't have a PairedMac shadow; helper must return nil rather than fall through to the Mac store."
        )
    }

    func testPairedMac_returnsNilForUnknownID() {
        XCTAssertNil(registry.pairedMac(for: "srt-id-that-does-not-exist"))
    }

    // MARK: - rename (kind-aware)

    func testRename_macDispatchesToPairedMacsStore() async throws {
        let macID = try await seedMac(host: "srt-host-rename-mac.test", name: "rename-source")

        let result = registry.rename(serverID: macID.uuidString, to: "Renamed Mac")
        registry.refreshFromLegacyStores()
        XCTAssertEqual(result, .success)

        let stored = try XCTUnwrap(pairedMacs.macs.first(where: { $0.macID == macID }))
        XCTAssertEqual(stored.alias, "Renamed Mac",
            "Mac rename must reach `PairedMacsStore.setAlias` so the keychain-tied display name updates."
        )
        let mirrored = try XCTUnwrap(registry.server(id: macID.uuidString))
        XCTAssertEqual(mirrored.alias, "Renamed Mac",
            "Mirror must republish the registry entry with the new alias."
        )
    }

    func testRename_linuxDispatchesToSessionStore() async throws {
        let linuxID = try await seedLinux(host: "srt-host-rename-linux.test", name: "linux-original")

        let result = registry.rename(serverID: linuxID, to: "Renamed Linux")
        registry.refreshFromLegacyStores()
        XCTAssertEqual(result, .success)

        let stored = try XCTUnwrap(sessionStore.pairedServers.first(where: { $0.id == linuxID }))
        XCTAssertEqual(stored.name, "Renamed Linux",
            "Linux rename must reach `SessionStore.renameServer` so the credential row updates."
        )
    }

    func testRename_macWritesCanonicalStoreSynchronously() async throws {
        let macID = try await seedMac(host: "srt-host-rename-canonical-mac.test", name: "canonical-source")

        let result = registry.rename(serverID: macID.uuidString, to: "Canonical Mac")
        XCTAssertEqual(result, .success)

        let published = try XCTUnwrap(registry.server(id: macID.uuidString))
        XCTAssertEqual(published.alias, "Canonical Mac",
            "Registry-initiated Mac renames must publish immediately instead of waiting for the legacy mirror callback."
        )
        let persisted = try XCTUnwrap(ServerStore().load().first(where: { $0.id == macID.uuidString }))
        XCTAssertEqual(persisted.alias, "Canonical Mac",
            "Registry-initiated Mac renames must write the canonical ServerStore synchronously."
        )
        let legacy = try XCTUnwrap(pairedMacs.macs.first(where: { $0.macID == macID }))
        XCTAssertEqual(legacy.alias, "Canonical Mac",
            "The legacy Mac store still receives the mutation for pairing-secret compatibility."
        )
    }

    func testRename_linuxWritesCanonicalStoreSynchronously() async throws {
        let linuxID = try await seedLinux(host: "srt-host-rename-canonical-linux.test", name: "linux-canonical-source")

        let result = registry.rename(serverID: linuxID, to: "Canonical Linux")
        XCTAssertEqual(result, .success)

        let published = try XCTUnwrap(registry.server(id: linuxID))
        XCTAssertEqual(published.displayName, "Canonical Linux",
            "Registry-initiated Linux renames must publish immediately instead of waiting for the legacy mirror callback."
        )
        let persisted = try XCTUnwrap(ServerStore().load().first(where: { $0.id == linuxID }))
        XCTAssertEqual(persisted.displayName, "Canonical Linux",
            "Registry-initiated Linux renames must write the canonical ServerStore synchronously."
        )
        let legacy = try XCTUnwrap(sessionStore.pairedServers.first(where: { $0.id == linuxID }))
        XCTAssertEqual(legacy.name, "Canonical Linux",
            "The legacy session store still receives the mutation for credential compatibility."
        )
    }

    func testRename_rejectsDuplicateAcrossKinds() async throws {
        let macID = try await seedMac(host: "srt-host-rename-dup-mac.test", name: "dup-source")
        let linuxID = try await seedLinux(host: "srt-host-rename-dup-linux.test", name: "linux-dup-source")

        _ = registry.rename(serverID: macID.uuidString, to: "Conflict Alias")
        registry.refreshFromLegacyStores()

        let result = registry.rename(serverID: linuxID, to: "Conflict Alias")
        guard case .duplicate = result else {
            return XCTFail("Cross-kind alias collision must yield .duplicate, got \(result). The Mac kept the alias; the Linux rename must be rejected.")
        }
    }

    func testRename_rejectsDuplicateVisibleNameAcrossKinds() async throws {
        let macID = try await seedMac(host: "srt-host-rename-visible-dup-mac.test", name: "Visible Name")
        let linuxID = try await seedLinux(host: "srt-host-rename-visible-dup-linux.test", name: "linux-visible-source")

        let result = registry.rename(serverID: linuxID, to: "Visible Name")
        guard case .duplicate = result else {
            return XCTFail("Cross-kind display-name collision must yield .duplicate, got \(result).")
        }

        let mac = try XCTUnwrap(registry.server(id: macID.uuidString))
        XCTAssertEqual(mac.displayName, "Visible Name")
        let linux = try XCTUnwrap(registry.server(id: linuxID))
        XCTAssertEqual(linux.displayName, "linux-visible-source",
            "Rejected duplicate renames must not mutate the canonical registry row."
        )
    }

    func testRename_rejectsEmptyAlias() async throws {
        let macID = try await seedMac(host: "srt-host-rename-empty.test", name: "empty-source")

        let result = registry.rename(serverID: macID.uuidString, to: "   ")
        guard case .invalid(.empty) = result else {
            return XCTFail("Whitespace-only alias must yield .invalid(.empty), got \(result).")
        }
    }

    func testRename_returnsSuccessWhenAliasUnchanged() async throws {
        let macID = try await seedMac(host: "srt-host-rename-noop.test", name: "noop-source")
        _ = registry.rename(serverID: macID.uuidString, to: "Stable")
        registry.refreshFromLegacyStores()

        let result = registry.rename(serverID: macID.uuidString, to: "Stable")
        XCTAssertEqual(result, .success,
            "Renaming to the same alias is idempotent — no second mirror cycle required."
        )
    }

    // MARK: - remove (kind-aware)

    func testRemove_macClearsPairedMacsStore() async throws {
        let macID = try await seedMac(host: "srt-host-remove-mac.test", name: "remove-source")
        let serverID = macID.uuidString

        registry.remove(serverID: serverID)
        registry.refreshFromLegacyStores()
        // Stop tracking so tearDown doesn't try to re-remove.
        createdMacIDs.removeAll { $0 == macID }

        XCTAssertFalse(pairedMacs.macs.contains(where: { $0.macID == macID }),
            "Mac removal must propagate to `PairedMacsStore.remove(macID:)`."
        )
        XCTAssertFalse(registry.servers.contains(where: { $0.id == serverID }),
            "Mirror must drop the entry after the legacy store fires `onChange`."
        )
    }

    func testRemove_linuxClearsSessionStore() async throws {
        let linuxID = try await seedLinux(host: "srt-host-remove-linux.test", name: "remove-linux-source")

        registry.remove(serverID: linuxID)
        registry.refreshFromLegacyStores()
        createdSessionServerIDs.removeAll { $0 == linuxID }

        XCTAssertFalse(sessionStore.pairedServers.contains(where: { $0.id == linuxID }),
            "Linux removal must propagate to `SessionStore.removeServer(id:)`."
        )
        XCTAssertFalse(registry.servers.contains(where: { $0.id == linuxID }))
    }

    func testRemove_macDropsCanonicalStoreSynchronously() async throws {
        let macID = try await seedMac(host: "srt-host-remove-canonical-mac.test", name: "remove-canonical-source")
        let serverID = macID.uuidString

        registry.remove(serverID: serverID)
        createdMacIDs.removeAll { $0 == macID }

        XCTAssertFalse(registry.servers.contains(where: { $0.id == serverID }),
            "Registry-initiated Mac removals must publish immediately instead of waiting for the legacy mirror callback."
        )
        XCTAssertFalse(ServerStore().load().contains(where: { $0.id == serverID }),
            "Registry-initiated Mac removals must drop the canonical ServerStore row synchronously."
        )
        XCTAssertFalse(pairedMacs.macs.contains(where: { $0.macID == macID }),
            "The legacy Mac store still receives the removal for pairing-secret cleanup."
        )
    }

    func testRemove_linuxDropsCanonicalStoreSynchronously() async throws {
        let linuxID = try await seedLinux(host: "srt-host-remove-canonical-linux.test", name: "remove-canonical-linux")

        registry.remove(serverID: linuxID)
        createdSessionServerIDs.removeAll { $0 == linuxID }

        XCTAssertFalse(registry.servers.contains(where: { $0.id == linuxID }),
            "Registry-initiated Linux removals must publish immediately instead of waiting for the legacy mirror callback."
        )
        XCTAssertFalse(ServerStore().load().contains(where: { $0.id == linuxID }),
            "Registry-initiated Linux removals must drop the canonical ServerStore row synchronously."
        )
        XCTAssertFalse(sessionStore.pairedServers.contains(where: { $0.id == linuxID }),
            "The legacy session store still receives the removal for credential cleanup."
        )
    }

    func testRemove_unknownIDIsNoOp() {
        let countBefore = registry.count
        registry.remove(serverID: "srt-id-that-does-not-exist")
        XCTAssertEqual(registry.count, countBefore,
            "Removing an unknown id silently no-ops; matches the legacy stores' contract."
        )
    }

    // MARK: - secret-aware mirror

    func testRefreshFromLegacyStoresKeepsSecretOwningMacIDCanonical() throws {
        let macID = UUID()
        let host = "srt-secret-owner-\(macID.uuidString.lowercased()).test"
        let shadowID = UUID().uuidString

        pairedMacs.upsertMac(macID: macID, name: "machine-alpha", host: host)
        pairedMacs.storeSecret(Data([0x01, 0x02, 0x03, 0x04]), for: macID)
        createdMacIDs.append(macID)

        let shadow = PairedServer(
            id: shadowID,
            host: host,
            name: "machine-alpha",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        sessionStore.addServer(shadow, token: "srt-token-\(shadowID)")
        createdSessionServerIDs.append(shadowID)

        registry.refreshFromLegacyStores()

        let matches = registry.servers.filter { $0.kind == .mac && $0.lastHost == host }
        XCTAssertEqual(matches.count, 1)
        let canonical = try XCTUnwrap(matches.first)
        XCTAssertEqual(canonical.id, macID.uuidString)
        XCTAssertNotNil(UUID(uuidString: canonical.id).flatMap { pairedMacs.secret(for: $0) })
    }

    func testRefreshFromLegacyStoresCollapsesNewMacRecordsWithSameEngineMachineId() throws {
        let unique = UUID().uuidString.lowercased()
        let machineID = "machine-alpha-\(unique)"
        let macID = UUID()
        let shadowID = "srt-shadow-\(unique)"

        pairedMacs.upsertMac(
            macID: macID,
            name: "machine-alpha",
            host: "mac-alpha-\(unique).test",
            engineMachineId: machineID
        )
        pairedMacs.storeSecret(Data([0x11, 0x22, 0x33, 0x44]), for: macID)
        createdMacIDs.append(macID)

        let shadow = PairedServer(
            id: shadowID,
            host: "mac-alpha-alt-\(unique).test",
            name: "machine-alpha",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine,
            engineMachineId: machineID
        )
        sessionStore.addServer(shadow, token: "srt-token-\(shadowID)")
        createdSessionServerIDs.append(shadowID)

        registry.refreshFromLegacyStores()

        let matches = registry.servers.filter { $0.kind == .mac && $0.engineMachineId == machineID }
        XCTAssertEqual(matches.count, 1)
        let canonical = try XCTUnwrap(matches.first)
        XCTAssertEqual(canonical.id, macID.uuidString)
        XCTAssertNotNil(UUID(uuidString: canonical.id).flatMap { pairedMacs.secret(for: $0) })
    }

    // MARK: - Helpers

    @discardableResult
    private func seedMac(host: String, name: String) async throws -> UUID {
        let macID = UUID()
        // Append the macID to the host so each test's Mac has a
        // unique `lastHost`. Without this, `ServerStore.reconcile`'s
        // Mac-collapse pass can merge our Mac with a Mac left in
        // UserDefaults by a prior test run (simulator UserDefaults
        // persists across xcodebuild invocations), dropping our
        // entry from the unified registry and causing `remove`
        // dispatch to no-op via the `guard let target = server(id:)`
        // early return.
        let uniqueHost = "\(host)-\(macID.uuidString.lowercased())"
        pairedMacs.upsertMac(macID: macID, name: name, host: uniqueHost)
        createdMacIDs.append(macID)
        // Drain the production async mirror synchronously — see
        // class docstring for why `Task.yield()` isn't enough in the
        // full-suite case.
        registry.refreshFromLegacyStores()
        return macID
    }

    @discardableResult
    private func seedLinux(host: String, name: String) async throws -> String {
        let id = "srt-linux-\(UUID().uuidString)"
        let server = PairedServer(
            id: id,
            host: host,
            name: name,
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )
        sessionStore.addServer(server, token: "srt-token-\(id)")
        createdSessionServerIDs.append(id)
        registry.refreshFromLegacyStores()
        return id
    }
}
