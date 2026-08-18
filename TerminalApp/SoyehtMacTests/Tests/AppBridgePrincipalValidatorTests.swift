import XCTest
@testable import SoyehtMacDomain

/// The principal validator is the phase-defining defense and the E2E cannot
/// reach it (the 2a CSP blocks subframe loads entirely — measured). So the
/// subframe, foreign-origin, and empty-host cases are exercised HERE, with
/// synthetic fixtures, including the ORDER: a message failing two checks
/// must be refused for the FIRST reason (contract §2).
final class AppBridgePrincipalValidatorTests: XCTestCase {
    // Fixtures are literal data on purpose: the domain package must not
    // import WebKit, so the app-side scheme builder is out of reach here.
    private let world = AppBridgePrincipalValidator.worldName
    private let scheme = "soyehtapp-probe-phase2a"

    private func refusal(
        worldName: String? = nil,
        isMainFrame: Bool = true,
        scheme: String? = nil,
        host: String = "local",
        port: Int = 0
    ) -> AppBridgePrincipalRefusal? {
        AppBridgePrincipalValidator.firstRefusal(
            worldName: worldName ?? world,
            isMainFrame: isMainFrame,
            scheme: scheme ?? self.scheme,
            host: host,
            port: port,
            expectedWorldName: world,
            expectedScheme: self.scheme,
            expectedHost: "local"
        )
    }

    func testValidMainFrameMessageIsAllowed() {
        XCTAssertNil(refusal())
    }

    func testSubframeIsRefusedEvenWithTheRightOrigin() {
        // about:blank/srcdoc subframes INHERIT the parent origin — the
        // origin triple is identical, so only isMainFrame can refuse this.
        XCTAssertEqual(refusal(isMainFrame: false), .subframe)
    }

    func testForeignOriginIsRefused() {
        XCTAssertEqual(refusal(scheme: "https"), .foreignOrigin)
        XCTAssertEqual(refusal(host: "evil.local"), .foreignOrigin)
        XCTAssertEqual(refusal(port: 8443), .foreignOrigin)
    }

    func testEmptyHostIsRefused() {
        // Reaches step 4 only if scheme and port match — constructible by
        // making the expected host empty, which is exactly the future the
        // contract keeps the step for.
        let verdict = AppBridgePrincipalValidator.firstRefusal(
            worldName: world, isMainFrame: true,
            scheme: scheme, host: "", port: 0,
            expectedWorldName: world, expectedScheme: scheme, expectedHost: ""
        )
        XCTAssertEqual(verdict, .emptyHost)
    }

    // MARK: - Order is the contract

    func testWrongWorldBeatsSubframe() {
        XCTAssertEqual(refusal(worldName: "page", isMainFrame: false), .wrongWorld)
    }

    func testSubframeBeatsForeignOrigin() {
        // A same-origin-inheriting subframe that ALSO looks foreign must
        // still be reported as the frame violation it is.
        XCTAssertEqual(refusal(isMainFrame: false, scheme: "https"), .subframe)
    }

    func testForeignOriginBeatsEmptyHost() {
        XCTAssertEqual(refusal(host: ""), .foreignOrigin)
    }

    func testPageWorldIsRefused() {
        // The page world's name is nil — a message from it can never be
        // the bridge's world.
        let verdict = AppBridgePrincipalValidator.firstRefusal(
            worldName: nil, isMainFrame: true,
            scheme: scheme, host: "local", port: 0,
            expectedWorldName: world, expectedScheme: scheme, expectedHost: "local"
        )
        XCTAssertEqual(verdict, .wrongWorld)
    }
}
