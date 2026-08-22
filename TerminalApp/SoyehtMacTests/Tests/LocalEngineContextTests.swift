import XCTest
@preconcurrency import SoyehtCore
@testable import SoyehtMacDomain

/// `LocalEngineContext.resolve()` must always target THIS Mac's own embedded
/// engine, never `SessionStore.activeServer` (which may point at a remote
/// Mac/Linux instance the user has selected in the UI) — spawning `argv` is
/// host code execution on whichever machine the resolved context names.
@MainActor
final class LocalEngineContextTests: XCTestCase {
    private func makeIsolatedSessionStore() -> SessionStore {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.soyeht.tests.localEngineContext.\(id)")!
        defaults.removePersistentDomain(forName: "com.soyeht.tests.localEngineContext.\(id)")
        return SessionStore(
            defaults: defaults,
            keychainService: "com.soyeht.mobile.tests.localEngineContext.\(id)"
        )
    }

    func testResolvesExistingLocalEngineRowWithoutSelfPairing() async {
        let store = makeIsolatedSessionStore()
        let localHost = SoyehtInstallProfile.current.adminHost
        let localEngineRow = PairedServer(
            id: "local-engine",
            host: localHost,
            name: "this-mac",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )
        // A DIFFERENT remote server is active — resolve() must still find the
        // local engine row by host, not whatever `activeServer` currently is.
        let remoteServer = PairedServer(
            id: "remote",
            host: "linux-alpha.example.ts.net",
            name: "remote",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .adminHost
        )
        store.addServer(localEngineRow, token: "local-token")
        store.addServer(remoteServer, token: "remote-token")
        store.setActiveServer(id: remoteServer.id)

        var autoPairCalled = false
        let context = await LocalEngineContext.resolve(store: store) {
            autoPairCalled = true
            throw NSError(domain: "test", code: 1)
        }

        XCTAssertFalse(autoPairCalled, "must not self-pair when a local engine row already exists")
        XCTAssertEqual(context?.host, localHost)
        XCTAssertEqual(context?.token, "local-token")
        XCTAssertEqual(context?.server.kind, .engine)
    }

    func testSelfPairsWhenNoLocalEngineRowExists() async {
        let store = makeIsolatedSessionStore()
        let selfPaired = PairedServer(
            id: "freshly-paired",
            host: SoyehtInstallProfile.current.adminHost,
            name: "this-mac",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )

        let context = await LocalEngineContext.resolve(store: store) {
            _ = store.addServer(selfPaired, token: "minted-token")
            return selfPaired
        }

        XCTAssertEqual(context?.server.id, "freshly-paired")
        XCTAssertEqual(context?.token, "minted-token")
    }

    func testReturnsNilWhenSelfPairingFails() async {
        let store = makeIsolatedSessionStore()
        let context = await LocalEngineContext.resolve(store: store) {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "bootstrap token missing"])
        }
        XCTAssertNil(context)
    }

    /// The REAL self-pair records this Mac's engine row under its externally
    /// reachable hostname (tailnet DNS name), not `adminHost` — so resolution
    /// falls through to `autoPair()` and gets that row back. `resolve()` must
    /// pin the returned context's transport to the loopback admin host
    /// (keeping the row's token), or every local-terminal call targets the
    /// machine's public surface, which a different engine instance answers
    /// (live symptom: HTTP 405 from its SPA fallback → permanent `NativePTY`
    /// downgrade — the exact failure the E2E king test caught).
    func testAutoPairedTailnetHostIsPinnedToLoopbackAdminHost() async {
        let store = makeIsolatedSessionStore()
        let localHost = SoyehtInstallProfile.current.adminHost
        let tailnetRow = PairedServer(
            id: "self-tailnet",
            host: "https://mac-alpha.example.ts.net",
            name: "this-mac",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )

        let context = await LocalEngineContext.resolve(store: store) {
            _ = store.addServer(tailnetRow, token: "self-token")
            return tailnetRow
        }

        XCTAssertEqual(context?.host, localHost, "transport must be pinned to the loopback admin host")
        XCTAssertEqual(context?.token, "self-token", "the row's own credential must be kept")
        XCTAssertEqual(context?.server.kind, .engine)
        XCTAssertEqual(context?.server.id, "self-tailnet")
    }

    /// A later launch cannot assume that the one-time bootstrap pairing can
    /// be redeemed again. Reuse the sole persisted engine credential, but
    /// never its public host: the local-terminal request must still go only
    /// to this Mac's loopback engine.
    func testPersistedTailnetCredentialSurvivesRejectedRepairPairing() async {
        let store = makeIsolatedSessionStore()
        let localHost = SoyehtInstallProfile.current.adminHost
        let tailnetRow = PairedServer(
            id: "persisted-self-tailnet",
            host: "https://mac-alpha.example.ts.net",
            name: "this-mac",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )
        store.addServer(tailnetRow, token: "persisted-token")

        let context = await LocalEngineContext.resolve(store: store) {
            throw NSError(domain: "test", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "already paired"])
        }

        XCTAssertEqual(context?.host, localHost)
        XCTAssertEqual(context?.token, "persisted-token")
        XCTAssertEqual(context?.server.id, "persisted-self-tailnet")
    }

    func testRejectedRepairDoesNotGuessBetweenMultipleEngineCredentials() async {
        let store = makeIsolatedSessionStore()
        for id in ["engine-a", "engine-b"] {
            store.addServer(
                PairedServer(
                    id: id,
                    host: "https://\(id).example.ts.net",
                    name: id,
                    role: nil,
                    pairedAt: Date(),
                    expiresAt: nil,
                    kind: .engine
                ),
                token: "token-\(id)"
            )
        }

        let resolution = await LocalEngineContext.resolveDetailed(store: store) {
            throw NSError(domain: "test", code: 500)
        }

        guard case .unavailable = resolution else {
            return XCTFail("multiple engine credentials must fail closed; came \(resolution)")
        }
    }
    // MARK: - "Nothing answered yet" is not "there is nothing"
    //
    // MEASURED on a cold boot, 2026-08-20. The app started at 11:27:08 and
    // asked for the engine at 11:27:14; launchd started the engine at 11:27:45
    // — 31 seconds later. `resolve()` could only answer `nil`, the caller read
    // that as permanent, and every restored pane fell back to an in-process
    // PTY and stayed fragile for the whole session. The retry machinery
    // downstream was already correct; it was never armed.

    /// The exact error a cold boot produces: nothing is listening yet.
    func testAnEngineThatIsNotListeningYetIsWorthWaitingFor() async {
        let store = makeIsolatedSessionStore()
        let notListening = NSError(domain: NSURLErrorDomain, code: -1004,
                                   userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."])
        let resolution = await LocalEngineContext.resolveDetailed(store: store) { throw notListening }
        guard case .engineNotAnsweringYet = resolution else {
            return XCTFail("um engine que ainda não está a escutar tem de valer a pena esperar; veio \(resolution)")
        }
    }

    /// Every code that means "nothing answered", not just the measured one.
    func testEveryNotAnsweringCodeIsWorthWaitingFor() async {
        for code in LocalEngineContext.notAnsweringURLErrorCodes {
            let store = makeIsolatedSessionStore()
            let error = NSError(domain: NSURLErrorDomain, code: code)
            let resolution = await LocalEngineContext.resolveDetailed(store: store) { throw error }
            guard case .engineNotAnsweringYet = resolution else {
                return XCTFail("código \(code) devia valer a pena esperar; veio \(resolution)")
            }
        }
    }

    /// And a refusal is still a refusal: the engine answered, so waiting
    /// changes nothing. Without this the fix would turn every permanent
    /// failure into a 35-second stall before the same fallback.
    func testAnEngineThatAnswersAndRefusesIsNotWaitedFor() async {
        let store = makeIsolatedSessionStore()
        // 401: answered, rejected. Not a transport failure.
        let refused = NSError(domain: NSURLErrorDomain, code: 401)
        let resolution = await LocalEngineContext.resolveDetailed(store: store) { throw refused }
        guard case .unavailable = resolution else {
            return XCTFail("uma recusa não se resolve esperando; veio \(resolution)")
        }
    }

    /// The retry budget has to cover what was actually measured. A budget that
    /// expires before the engine exists classifies correctly and still loses
    /// the pane — which is the state this whole fix exists to leave behind.
    func testTheRetryBudgetCoversAColdBoot() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac/PaneGrid/PaneViewController.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let parts = source.components(separatedBy: "restoreRetryDelaysNanoseconds: [UInt64] = [")
        XCTAssertEqual(parts.count, 2, "a declaração do orçamento mudou de forma")
        let literal = parts[1].components(separatedBy: "]")[0]
        let total = literal.components(separatedBy: ",")
            .compactMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "")) }
            .reduce(0, +)
        let seconds = Double(total) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(seconds, 31,
                                    "o orçamento é \(seconds)s; o arranque a frio medido demorou 31s a ter engine")
    }

}
