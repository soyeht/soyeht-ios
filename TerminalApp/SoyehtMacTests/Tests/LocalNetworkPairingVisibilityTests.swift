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
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8091/bootstrap/pair-device/window/open")
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

        _ = try await client.close()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8101/bootstrap/pair-device/window/close")
    }

    /// The client asks for visibility and nothing else. Minting is
    /// `MacPairingAdvertisement`'s job, and `POST
    /// /bootstrap/pair-device/reissue` would mint a second offer whose words
    /// disagree with the six already on screen.
    func test_visibilityClientNeverTouchesTheReissueOrPairDeviceURIRoutes() throws {
        let source = try coreSource("Bootstrap/BootstrapPairDeviceWindowClient.swift")
        XCTAssertFalse(source.contains("\"/bootstrap/pair-device/reissue\""))
        XCTAssertFalse(source.contains("\"/bootstrap/pair-device-uri\""))
        XCTAssertTrue(source.contains("static let openPath = \"/bootstrap/pair-device/window/open\""))
        XCTAssertTrue(source.contains("static let closePath = \"/bootstrap/pair-device/window/close\""))
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

    private static func ackBody(expiresAt: UInt64?) -> Data {
        var map: [String: HouseholdCBORValue] = ["v": .unsigned(1)]
        if let expiresAt { map["expires_at"] = .unsigned(expiresAt) }
        return HouseholdCBOR.encode(.map(map))
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
