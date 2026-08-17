import Foundation
import RelayStreamGuestFFI
import SoyehtCore
import WebKit
import XCTest

@testable import Soyeht

private enum SentinelError: Error {
    case boom
}

/// Throws immediately, so `ClawSiteHTTPBridge.exchange()`'s uncaught
/// `opener.openClawSiteStream()` call (the direct-propagation path, no
/// wrapping) surfaces `error` straight through `bridge.perform(...)`.
private struct ThrowingStreamOpener: ClawSiteStreamOpening {
    let error: Error

    func openClawSiteStream() async throws -> any ClawSiteStreamSession {
        throw error
    }
}

/// Minimal `WKURLSchemeTask` conformer — no real `WKWebView` needed. This is
/// what makes the typed-channel proof possible: `ClawSiteURLSchemeHandler`
/// only needs the protocol, not a live web view.
private final class FakeURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var didFailWithErrorCallCount = 0
    private(set) var lastError: Error?

    init(request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) {}
    func didFinish() {}

    func didFailWithError(_ error: Error) {
        didFailWithErrorCallCount += 1
        lastError = error
    }
}

final class ClawSiteURLSchemeHandlerTests: XCTestCase {
    private func makeRequest() -> URLRequest {
        URLRequest(url: ClawSiteURLSchemeHandler.rootURL)
    }

    func test_typedFailureHandlerReceivesTheOriginalErrorCase() {
        // Cases directly, not `NSError`/`localizedDescription` — the whole
        // point of this channel is that the ORIGINAL Swift type survives.
        let injected = RelayStreamGuestError.AuthRejected(
            "target service unavailable: relay-stream-share-app-unavailable"
        )
        let handler = ClawSiteURLSchemeHandler(
            bridge: ClawSiteHTTPBridge(opener: ThrowingStreamOpener(error: injected))
        )
        let expectation = expectation(description: "typed failure handler invoked")
        var received: Error?
        handler.setTypedFailureHandler { error in
            received = error
            expectation.fulfill()
        }

        let task = FakeURLSchemeTask(request: makeRequest())
        handler.start(task)

        wait(for: [expectation], timeout: 2)

        guard case .AuthRejected(let reason) = received as? RelayStreamGuestError else {
            return XCTFail("expected RelayStreamGuestError.AuthRejected, got \(String(describing: received))")
        }
        XCTAssertEqual(reason, "target service unavailable: relay-stream-share-app-unavailable")
        // `didFailWithError` must still fire — required by the
        // `WKURLSchemeTask` lifecycle contract, independent of the typed
        // channel.
        XCTAssertEqual(task.didFailWithErrorCallCount, 1)
    }

    func test_typedFailureHandlerIsInvokedOutsideTheLock() {
        // Non-vacuity: merely asserting the callback fired doesn't prove it
        // ran outside the lock. Reentering `setTypedFailureHandler` FROM
        // WITHIN the callback does: `NSLock` is not reentrant, so if `fail`
        // still held the lock while invoking the callback, this would
        // deadlock and the expectation would time out instead of fulfilling.
        let handler = ClawSiteURLSchemeHandler(
            bridge: ClawSiteHTTPBridge(opener: ThrowingStreamOpener(error: SentinelError.boom))
        )
        let expectation = expectation(description: "reentrant install completed without deadlock")

        handler.setTypedFailureHandler { [weak handler] _ in
            handler?.setTypedFailureHandler { _ in }
            expectation.fulfill()
        }

        let task = FakeURLSchemeTask(request: makeRequest())
        handler.start(task)

        wait(for: [expectation], timeout: 2)
    }
}
