import Foundation
import SoyehtCore
import XCTest

@testable import Soyeht

private struct UnusedStreamOpener: ClawSiteStreamOpening {
    func openClawSiteStream() async throws -> any ClawSiteStreamSession {
        throw ClawSiteBridgeError.streamFailed("not exercised by this test")
    }
}

private func makeHandler() -> ClawSiteURLSchemeHandler {
    ClawSiteURLSchemeHandler(bridge: ClawSiteHTTPBridge(opener: UnusedStreamOpener()))
}

/// `ClawSiteWebViewReloadPolicy.shouldReload` is what `updateUIView` actually
/// calls to decide whether to reload — these tests cover that DECISION
/// directly, not just the identity-tracking primitives it's built from.
///
/// This is a policy-unit test, not a callsite/integration test:
/// `UIViewRepresentable.Context` has no public initializer — SwiftUI vends
/// it only from a real, running view hierarchy — so `updateUIView` itself
/// cannot be invoked from a plain XCTest without hosting an actual SwiftUI
/// tree (e.g. a `UIHostingController`-based UI test, out of scope here).
final class ClawSiteWebViewReloadPolicyTests: XCTestCase {
    func test_noHandlerLoadedYetNeedsReload() {
        XCTAssertTrue(
            ClawSiteWebViewReloadPolicy.shouldReload(loadedHandler: nil, requestedHandler: makeHandler())
        )
    }

    func test_sameSourceNeverNeedsReload_regardlessOfWhereTheGuestHasNavigated() {
        // The policy takes no `webView.url` parameter at all — that's the
        // point. As long as the source is the same handler instance,
        // in-page navigation (which moves `webView.url` away from the root)
        // cannot affect the answer. This IS "preserve navigation": the
        // decision structurally can't see the thing that must not matter.
        let handler = makeHandler()

        XCTAssertFalse(
            ClawSiteWebViewReloadPolicy.shouldReload(loadedHandler: handler, requestedHandler: handler)
        )
    }

    func test_aGenuinelyDifferentSourceNeedsReload() {
        // A different claimed session — the one case that SHOULD reload.
        let loaded = makeHandler()
        let requested = makeHandler()

        XCTAssertTrue(
            ClawSiteWebViewReloadPolicy.shouldReload(loadedHandler: loaded, requestedHandler: requested)
        )
    }
}

/// `Coordinator`'s own bookkeeping: `markLoaded` records a STRONG reference
/// (not just an `ObjectIdentifier`), so a deallocated handler's address can
/// never be mistaken for a live, different one — see `loadedHandler`'s doc
/// comment in ClawSiteView.swift for the bug this caught on the first
/// version of this fix (a plain `ObjectIdentifier` did collide in exactly
/// this scenario once the identified object was freed).
final class ClawSiteWebViewCoordinatorTests: XCTestCase {
    func test_startsWithNoHandlerLoaded() {
        let coordinator = ClawSiteWebView.Coordinator(onFailure: { _ in })

        XCTAssertNil(coordinator.loadedHandler)
    }

    func test_markLoadedRecordsTheExactHandler() {
        let coordinator = ClawSiteWebView.Coordinator(onFailure: { _ in })
        let handler = makeHandler()

        coordinator.markLoaded(handler)

        XCTAssertTrue(coordinator.loadedHandler === handler)
    }

    func test_markingASecondHandlerReplacesTheFirst() {
        let coordinator = ClawSiteWebView.Coordinator(onFailure: { _ in })
        let first = makeHandler()
        let second = makeHandler()
        coordinator.markLoaded(first)

        coordinator.markLoaded(second)

        XCTAssertFalse(coordinator.loadedHandler === first)
        XCTAssertTrue(coordinator.loadedHandler === second)
    }

    func test_coordinatorStatePlusPolicyCorrectlyDetectsAGenuinelyNewSource() {
        // End-to-end within what's actually testable: Coordinator records
        // state, the policy consumes exactly that state to decide reload —
        // the same two pieces `updateUIView` wires together at the callsite.
        let coordinator = ClawSiteWebView.Coordinator(onFailure: { _ in })
        coordinator.markLoaded(makeHandler())
        let requested = makeHandler()

        XCTAssertTrue(
            ClawSiteWebViewReloadPolicy.shouldReload(
                loadedHandler: coordinator.loadedHandler,
                requestedHandler: requested
            ),
            "a different handler instance is a different source and must reload"
        )
    }
}
