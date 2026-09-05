import XCTest
import os
import SoyehtCore
@testable import SoyehtMacDomain

/// The gap these tests lock: on a household that is already set up, "Add
/// iPhone" never opened the engine's pair-device window, so
/// `HouseholdExposurePolicy` saw `Closed` and the LAN never bound. The sheet's
/// only engine call was `GET /bootstrap/pair-device-uri`, the first-owner
/// route, which answers 404 once an owner exists.
final class LocalNetworkPairingVisibilityTests: XCTestCase {

    // MARK: - The two asks, and their shape on the wire

    func test_openPostsTheWindowOpenRouteWithNoAuthorization() async throws {
        let recorder = RequestRecorder()
        let client = BootstrapPairDeviceWindowClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: recorder.transport(responding: Self.ackBody(expiresAt: 1_757_000_000))
        )

        let ack = try await client.open()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8091/bootstrap/local-network-visibility/open")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/cbor")
        // Loopback is the engine's admission check for this route, exactly as
        // for `POST /bootstrap/pair-device/reissue`. No household signature.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpBody, HouseholdCBOR.encode(.map(["v": .unsigned(1)])))
        XCTAssertEqual(ack.expiresAt, 1_757_000_000)
    }

    func test_closePostsTheWindowCloseRoute() async throws {
        let recorder = RequestRecorder()
        let client = BootstrapPairDeviceWindowClient(
            baseURL: URL(string: "http://127.0.0.1:8101")!,
            transport: recorder.transport(responding: Self.ackBody(expiresAt: nil))
        )

        let ack = try await client.close()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8101/bootstrap/local-network-visibility/close")
        // Close answers `expires_at_unix: null` — present, and null. Reading
        // that as a protocol violation would make every successful close report
        // a failure.
        XCTAssertNil(ack.expiresAt)
    }

    /// The mismatch an adversarial review caught, and the reason this file no
    /// longer trusts its own invention: the first version of this client called
    /// `/bootstrap/pair-device/window/{open,close}` and read `expires_at`,
    /// while the engine serves `/bootstrap/local-network-visibility/{open,close}`
    /// and writes `expires_at_unix`. BOTH suites were green — each side pinned
    /// what it had made up — and the feature was dead end to end, silently,
    /// because every caller treats a failure as "no Wi-Fi bonus" and carries on.
    ///
    /// The engine is a sibling checkout, not a dependency, so a machine without
    /// it skips rather than fails.
    func test_theEngineServesTheRoutesThisClientCalls() throws {
        let engine = try engineSource("local_network_visibility.rs")
        let client = try coreSource("Bootstrap/BootstrapPairDeviceWindowClient.swift")

        for path in [
            "/bootstrap/local-network-visibility/open",
            "/bootstrap/local-network-visibility/close",
        ] {
            XCTAssertTrue(client.contains("\"\(path)\""), "the client stopped calling \(path)")
            XCTAssertTrue(engine.contains("\"\(path)\""), "the engine stopped serving \(path)")
        }
        XCTAssertTrue(client.contains("expiresAtKey = \"expires_at_unix\""))
        XCTAssertTrue(
            engine.contains("expires_at_unix: Option<u64>"),
            "the engine renamed or retyped the deadline the client decodes"
        )
    }

    /// The client asks for visibility and nothing else. Minting is
    /// `MacPairingAdvertisement`'s job, and `POST
    /// /bootstrap/pair-device/reissue` would mint a second offer whose words
    /// disagree with the six already on screen.
    func test_visibilityClientNeverTouchesTheReissueOrPairDeviceURIRoutes() throws {
        let source = try coreSource("Bootstrap/BootstrapPairDeviceWindowClient.swift")
        XCTAssertFalse(source.contains("\"/bootstrap/pair-device/reissue\""))
        XCTAssertFalse(source.contains("\"/bootstrap/pair-device-uri\""))
        XCTAssertTrue(source.contains("static let openPath = \"/bootstrap/local-network-visibility/open\""))
        XCTAssertTrue(source.contains("static let closePath = \"/bootstrap/local-network-visibility/close\""))
    }

    // MARK: - Open on presentation, close on every exit

    func test_openIsIssuedWhenTheSheetIsPresented() async {
        let engine = VisibilitySpy()
        let visibility = await LocalNetworkPairingVisibility(requester: engine, sleeper: Self.neverReturns)

        await visibility.begin()
        await visibility.settle()

        XCTAssertEqual(engine.calls, [.open])
    }

    func test_closeIsIssuedWhenTheSheetIsDismissed() async {
        let engine = VisibilitySpy()
        let visibility = await LocalNetworkPairingVisibility(requester: engine, sleeper: Self.neverReturns)

        await visibility.begin()
        await visibility.end()
        await visibility.settle()

        XCTAssertEqual(engine.calls, [.open, .close])
    }

    /// The sheet's completion handler and the content's `viewDidDisappear`
    /// both fire on a normal dismissal. The engine window must close once, and
    /// the second call must not go negative and re-close a window a later
    /// sheet has opened.
    func test_asecondEndOnTheSameSheetDoesNotIssueASecondClose() async {
        let engine = VisibilitySpy()
        let visibility = await LocalNetworkPairingVisibility(requester: engine, sleeper: Self.neverReturns)

        await visibility.begin()
        await visibility.end()
        await visibility.end()
        await visibility.settle()

        XCTAssertEqual(engine.calls, [.open, .close])
    }

    func test_quittingWithTheSheetOpenClosesTheWindow() async {
        let engine = VisibilitySpy()
        let visibility = await LocalNetworkPairingVisibility(requester: engine, sleeper: Self.neverReturns)

        await visibility.begin()
        await visibility.settle()
        await Self.quit(visibility)

        XCTAssertEqual(engine.calls, [.open, .close])
    }

    /// Quitting with no Add iPhone window open must not talk to the engine at
    /// all — every quit would otherwise carry a pointless request that can
    /// only block.
    func test_quittingWithNoSheetOpenIssuesNothing() async {
        let engine = VisibilitySpy()
        let visibility = await LocalNetworkPairingVisibility(requester: engine, sleeper: Self.neverReturns)

        await Self.quit(visibility)

        XCTAssertEqual(engine.calls, [])
    }

    /// Dismiss and quit in the same breath. `applicationWillTerminate` runs
    /// synchronously on the main thread, so the close `end()` queued CANNOT
    /// run before the process dies — which is why the quit gate has to ask
    /// "is a window still open at the engine", not "is a sheet on screen".
    /// Gated on the sheet, this path issued nothing and the home stayed
    /// discoverable on the Wi-Fi until the engine's TTL ran out.
    func test_dismissingAndQuittingInTheSameBreathStillClosesTheWindow() async {
        let engine = VisibilitySpy()
        let visibility = await LocalNetworkPairingVisibility(requester: engine, sleeper: Self.neverReturns)

        await visibility.begin()
        await visibility.settle()

        // Both on the main actor with nothing awaited in between, and the
        // engine read from INSIDE that block: exactly the interleaving AppKit
        // gives a quit. The queued close never gets a turn, so anything
        // recorded here was recorded by the quit itself. Reading after the
        // block would hand the main actor back and let the queue drain — which
        // a terminating process never does.
        let recordedDuringQuit = await MainActor.run { () -> [VisibilityCall] in
            visibility.end()
            visibility.closeOnTermination()
            return engine.calls
        }

        XCTAssertEqual(
            recordedDuringQuit, [.open, .close],
            "the quit path never asked the engine to stop being visible"
        )

        // And the close still sitting in the queue must not fire a second one.
        await visibility.settle()
        XCTAssertEqual(engine.calls, [.open, .close])
    }

    // MARK: - Failure is quiet

    /// The engine half of this is not merged, so today every call fails with a
    /// 404 that is not even CBOR. That must stay a no-op: the sheet still
    /// opens and a phone with Tailscale still pairs.
    func test_anEngineThatNeverAnswersDoesNotBlockOrThrow() async {
        let engine = VisibilitySpy(failure: BootstrapError.networkDrop)
        let visibility = await LocalNetworkPairingVisibility(requester: engine, sleeper: Self.neverReturns)

        await visibility.begin()
        await visibility.end()
        await visibility.settle()

        XCTAssertEqual(engine.calls, [.open, .close])
    }

    // MARK: - The window is time-boxed, so an open sheet renews it

    /// The engine's pair-device TTL floor is 60 s, so a sheet left open longer
    /// than the window would silently stop being visible. A repeat open
    /// extends rather than mints.
    func test_anOpenSheetRenewsTheWindowUntilItIsDismissed() async {
        let engine = VisibilitySpy()
        let sleeps = Counter()
        let visibility = await LocalNetworkPairingVisibility(
            requester: engine,
            renewInterval: .seconds(20),
            sleeper: { _ in
                // Three renewals, then behave like a cancelled sleep so the
                // loop ends deterministically instead of on a wall clock.
                if sleeps.increment() > 3 { throw CancellationError() }
            }
        )

        await visibility.begin()
        await visibility.renewalTask?.value
        await visibility.settle()

        XCTAssertEqual(engine.calls, [.open, .open, .open, .open])
        XCTAssertLessThan(LocalNetworkPairingVisibility.defaultRenewInterval, .seconds(60))
    }

    /// A renewal in flight when the sheet is dismissed. The renewal used to go
    /// straight to the engine instead of onto the request chain, so the engine
    /// could answer the close first and the renewal second — re-opening the
    /// window the person had just dismissed and leaving the home on the Wi-Fi
    /// for a whole TTL. The close must therefore wait behind the renewal.
    func test_aCloseNeverOvertakesARenewalThatIsStillInFlight() async {
        let engine = GatedVisibilitySpy(gateFrom: 2)
        let sleeps = Counter()
        let visibility = await LocalNetworkPairingVisibility(
            requester: engine,
            renewInterval: .seconds(20),
            sleeper: { _ in if sleeps.increment() > 1 { throw CancellationError() } }
        )

        await visibility.begin()
        // The renewal has reached the engine and is sitting inside the call.
        // Waiting on the engine rather than on `renewalTask`: a renewal that
        // talks to the engine from inside the loop never returns while it is
        // gated, and the test would hang instead of reporting.
        await engine.waitForOpenStarts(2)

        await visibility.end()
        // Hand the main actor back several times so anything the close is
        // free to do, it does. Behind the chain it can do nothing: the
        // renewal is still inside the engine call.
        for _ in 0..<5 { await MainActor.run {} }
        XCTAssertEqual(
            engine.calls, [.openStarted, .openFinished, .openStarted],
            "the close overtook a renewal that had not been answered yet"
        )

        engine.release()
        await visibility.settle()
        XCTAssertEqual(
            engine.calls,
            [.openStarted, .openFinished, .openStarted, .openFinished, .close]
        )
    }

    // MARK: - The call sites

    func test_addIPhoneSheetOpensAndClosesTheEngineWindowOnEveryExitPath() throws {
        let source = try macSource("PreferencesDevicesViewController.swift")
        let addIPhone = try slice(
            source,
            from: "@objc private func addIPhone()",
            to: "/// Two buttons, and the destructive one is not the default"
        )
        let hosting = try slice(
            source,
            from: "private final class MacIPhonePairingHostingController",
            to: "private final class MacIPhonePairingPreferencesModel"
        )

        // Presented → open.
        XCTAssertTrue(hosting.contains("override func viewDidAppear()"))
        XCTAssertTrue(hosting.contains("LocalNetworkPairingVisibility.shared.begin()"))
        // Sheet completion → close.
        XCTAssertTrue(addIPhone.contains("controller.releaseLocalNetworkVisibility()"))
        // Window closed → close.
        XCTAssertTrue(hosting.contains("releaseLocalNetworkVisibility()"))
        XCTAssertTrue(hosting.contains("LocalNetworkPairingVisibility.shared.end()"))
        // Still refreshes the badge it always refreshed.
        XCTAssertTrue(addIPhone.contains("self?.refreshLocalConnectionCount()"))
    }

    func test_quittingClosesTheEngineWindowFromApplicationWillTerminate() throws {
        let source = try macSource("AppDelegate.swift")
        let willTerminate = try slice(
            source,
            from: "func applicationWillTerminate(",
            to: "func applicationShouldTerminateAfterLastWindowClosed("
        )

        XCTAssertTrue(willTerminate.contains("LocalNetworkPairingVisibility.shared.closeOnTermination()"))
    }

    /// Dev and production each talk to their own engine, on their own
    /// bootstrap port.
    func test_visibilityResolvesTheBaseURLFromTheInstallProfile() throws {
        let source = try macSource("Pairing/LocalNetworkPairingVisibility.swift")
        XCTAssertTrue(source.contains("TheyOSEnvironment.bootstrapBaseURL"))
        XCTAssertFalse(source.contains("127.0.0.1:"))
    }

    // MARK: - Helpers

    private static let neverReturns: @Sendable (Duration) async throws -> Void = { _ in
        throw CancellationError()
    }

    /// `closeOnTermination()` blocks its caller, which is legitimate on the
    /// main thread inside `applicationWillTerminate` but must never block a
    /// Swift concurrency worker. Call it the way AppKit does: off the
    /// cooperative pool.
    private static func quit(_ visibility: LocalNetworkPairingVisibility) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                visibility.closeOnTermination()
                continuation.resume()
            }
        }
    }

    /// The engine's body field for field
    /// (`local_network_visibility::VisibilityResponse`): three keys, and on
    /// close `expires_at_unix` is present AND null — the field is an
    /// `Option<u64>` with no `skip_serializing_if`, so serde writes the null.
    private static func ackBody(expiresAt: UInt64?) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "open": .bool(expiresAt != nil),
            "expires_at_unix": expiresAt.map { HouseholdCBORValue.unsigned($0) } ?? .null,
        ]))
    }

    /// The engine repo, sibling to this one. `THEYOS_REPO` overrides for a
    /// checkout somewhere else; missing means skip, not fail.
    private func engineSource(_ fileName: String) throws -> String {
        let root = ProcessInfo.processInfo.environment["THEYOS_REPO"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/theyos")
        let url = root
            .appendingPathComponent("admin/rust/server-rs/src")
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("engine checkout not on this machine: \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func coreSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .deletingLastPathComponent()  // repo root
        let url = repoRoot
            .appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}

// MARK: - Doubles

private enum VisibilityCall: Equatable {
    case open
    case close
}

private final class VisibilitySpy: LocalNetworkPairingVisibilityRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [VisibilityCall] = []
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    var calls: [VisibilityCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    @discardableResult
    func open() async throws -> BootstrapPairDeviceWindowAck {
        try record(.open)
        return BootstrapPairDeviceWindowAck(version: 1, expiresAt: nil)
    }

    func close() async throws {
        try record(.close)
    }

    private func record(_ call: VisibilityCall) throws {
        lock.lock()
        recorded.append(call)
        lock.unlock()
        if let failure { throw failure }
    }
}

private enum GatedVisibilityCall: Equatable {
    case openStarted
    case openFinished
    case close
}

/// A spy that can hold an `open()` inside the engine call, so a test can ask
/// what the coordinator does while a request is unanswered — which is where
/// ordering bugs live. `VisibilitySpy` answers instantly and cannot see them.
private final class GatedVisibilitySpy: LocalNetworkPairingVisibilityRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GatedVisibilityCall] = []
    private var opensStarted = 0
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var released = false
    private let gateFrom: Int

    /// `gateFrom` is 1-based: the Nth open and every one after it wait.
    init(gateFrom: Int) {
        self.gateFrom = gateFrom
    }

    var calls: [GatedVisibilityCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    @discardableResult
    func open() async throws -> BootstrapPairDeviceWindowAck {
        lock.lock()
        recorded.append(.openStarted)
        opensStarted += 1
        let index = opensStarted
        let ready = startWaiters.filter { $0.count <= index }
        startWaiters.removeAll { $0.count <= index }
        let gated = index >= gateFrom && !released
        lock.unlock()
        ready.forEach { $0.continuation.resume() }

        if gated {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    gateWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        lock.lock()
        recorded.append(.openFinished)
        lock.unlock()
        return BootstrapPairDeviceWindowAck(version: 1, expiresAt: nil)
    }

    func close() async throws {
        lock.lock()
        recorded.append(.close)
        lock.unlock()
    }

    /// Returns once the engine has been asked to open at least `count` times.
    func waitForOpenStarts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opensStarted >= count {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiting = gateWaiters
        gateWaiters.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class RequestRecorder: Sendable {
    // `OSAllocatedUnfairLock` rather than `NSLock`: the transport closure is
    // async, and `NSLock.lock()` is unavailable from an async context.
    private let recorded = OSAllocatedUnfairLock(initialState: [URLRequest]())

    var requests: [URLRequest] {
        recorded.withLock { $0 }
    }

    func transport(responding body: Data) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            self.recorded.withLock { $0.append(request) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/cbor"]
            )!
            return (body, response)
        }
    }
}
