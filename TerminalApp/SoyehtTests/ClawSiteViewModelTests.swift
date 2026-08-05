import Foundation
import RelayStreamGuestFFI
import SoyehtCore
import XCTest

@testable import Soyeht

private enum SentinelError: Error {
    case boom
}

/// Never actually invoked in these tests — `ClawSiteHTTPBridge` requires an
/// opener to construct, but nothing here drives a real HTTP exchange.
private struct UnusedStreamOpener: ClawSiteStreamOpening {
    func openClawSiteStream() async throws -> any ClawSiteStreamSession {
        throw SentinelError.boom
    }
}

/// Tracks call count. The SAME instance is injected once per test and
/// reused across resolve/retry — since it is the only provider in the
/// test's universe, any successful call through it is already proof the
/// SAME provider (and thus the same underlying bridge/opener/offer/
/// credential, all held one level deeper) was reused, not reconstructed.
private final class SpyEndpointProvider: ClawSiteEndpointProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0
    private let makeSource: () -> ClawSiteSource?

    init(makeSource: @escaping () -> ClawSiteSource?) {
        self.makeSource = makeSource
    }

    func source(forClaw clawName: String) async -> ClawSiteSource? {
        lock.lock()
        callCount += 1
        lock.unlock()
        return makeSource()
    }
}

@MainActor
final class ClawSiteViewModelTests: XCTestCase {
    private func makeSource() -> ClawSiteSource {
        ClawSiteSource(
            url: ClawSiteURLSchemeHandler.rootURL,
            handler: ClawSiteURLSchemeHandler(bridge: ClawSiteHTTPBridge(opener: UnusedStreamOpener()))
        )
    }

    private func makeReadyModel(provider: SpyEndpointProvider) async -> ClawSiteViewModel {
        let model = ClawSiteViewModel(clawName: "claw-alpha", provider: provider)
        await model.resolve()
        return model
    }

    private func unavailableError() -> Error {
        RelayStreamGuestError.AuthRejected("target service unavailable: relay-stream-share-app-unavailable")
    }

    private func noLongerAvailableError() -> Error {
        RelayStreamGuestError.AuthRejected("target service unavailable: relay-stream-share-app-no-longer-available")
    }

    // MARK: - Phase routing

    func test_recoverableUnavailableReasonRoutesToUnavailablePhase() async {
        let source = makeSource()
        let provider = SpyEndpointProvider(makeSource: { source })
        let model = await makeReadyModel(provider: provider)
        guard case .ready = model.phase else { return XCTFail("expected .ready before injecting the failure") }

        model.reportLoadFailure(unavailableError())

        XCTAssertEqual(model.phase, .unavailable)
    }

    func test_terminalReasonRoutesToFailedLinkNoLongerValid() async {
        let source = makeSource()
        let provider = SpyEndpointProvider(makeSource: { source })
        let model = await makeReadyModel(provider: provider)

        model.reportLoadFailure(noLongerAvailableError())

        guard case .failed(let failure) = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
        XCTAssertEqual(failure, .linkNoLongerValid)
    }

    func test_unrelatedReasonFallsBackToFailedUnknown() async {
        let source = makeSource()
        let provider = SpyEndpointProvider(makeSource: { source })
        let model = await makeReadyModel(provider: provider)

        model.reportLoadFailure(RelayStreamGuestError.AuthRejected("target service unavailable: relay-stream-slot-revoked"))

        guard case .failed(let failure) = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
        XCTAssertEqual(failure, .unknown)
    }

    // MARK: - Dedupe

    func test_secondFailureReportAfterTheFirstIsANoOp() async {
        // Simulates the direct typed channel and the WKNavigationDelegate
        // fallback both reporting the same underlying failure.
        let source = makeSource()
        let provider = SpyEndpointProvider(makeSource: { source })
        let model = await makeReadyModel(provider: provider)

        model.reportLoadFailure(unavailableError())
        XCTAssertEqual(model.phase, .unavailable)

        // A DIFFERENT error arriving second must not reclassify — proves
        // the guard is on phase, not on error identity/equality.
        model.reportLoadFailure(noLongerAvailableError())

        XCTAssertEqual(model.phase, .unavailable, "the first report must win; phase must not have been overwritten")
    }

    // MARK: - Provider/opener reuse across unavailable → retry

    func test_retryReusesTheSameProviderAndReachesReadyAgain() async {
        let source = makeSource()
        let provider = SpyEndpointProvider(makeSource: { source })
        let model = await makeReadyModel(provider: provider)
        XCTAssertEqual(provider.callCount, 1)

        model.reportLoadFailure(unavailableError())
        XCTAssertEqual(model.phase, .unavailable)

        await model.retry()

        XCTAssertEqual(provider.callCount, 2, "retry must call the SAME provider instance again, not construct a new one")
        XCTAssertEqual(model.phase, .ready(source))
    }
}
