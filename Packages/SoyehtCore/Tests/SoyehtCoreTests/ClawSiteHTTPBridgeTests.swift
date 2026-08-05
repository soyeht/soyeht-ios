import Foundation
import Testing
@testable import SoyehtCore

/// Scripted stream: replays a fixed frame sequence and records what was sent.
private actor ScriptedClawSiteSession: ClawSiteStreamSession {
    private var frames: [ClawSiteStreamFrame]
    private(set) var sent: [Data] = []
    private(set) var closeCount = 0

    init(frames: [ClawSiteStreamFrame]) {
        self.frames = frames
    }

    func send(_ data: Data) async throws { sent.append(data) }

    func nextFrame() async throws -> ClawSiteStreamFrame {
        guard !frames.isEmpty else { return .closed }
        return frames.removeFirst()
    }

    func close() async throws { closeCount += 1 }

    var sentBytes: Data { sent.reduce(into: Data()) { $0.append($1) } }
}

private struct ScriptedOpener: ClawSiteStreamOpening {
    let session: ScriptedClawSiteSession
    let onOpen: @Sendable () -> Void

    init(session: ScriptedClawSiteSession, onOpen: @escaping @Sendable () -> Void = {}) {
        self.session = session
        self.onOpen = onOpen
    }

    func openClawSiteStream() async throws -> any ClawSiteStreamSession {
        onOpen()
        return session
    }
}

private struct FailingOpener: ClawSiteStreamOpening {
    func openClawSiteStream() async throws -> any ClawSiteStreamSession {
        throw ClawSiteBridgeError.streamFailed("dial refused")
    }
}

/// Never yields a frame, so the bridge's own timeout is the only thing that
/// can end the exchange.
private struct HangingSession: ClawSiteStreamSession {
    func send(_ data: Data) async throws {}
    func nextFrame() async throws -> ClawSiteStreamFrame {
        try await Task.sleep(for: .seconds(3600))
        return .closed
    }
    func close() async throws {}
}

private struct HangingOpener: ClawSiteStreamOpening {
    func openClawSiteStream() async throws -> any ClawSiteStreamSession { HangingSession() }
}

@Suite("ClawSiteHTTPBridge")
struct ClawSiteHTTPBridgeTests {
    private static func okResponse(_ body: String) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    @Test func sendsSerializedRequestAndParsesResponse() async throws {
        let session = ScriptedClawSiteSession(frames: [
            .data(Self.okResponse("<h1>House finances</h1>")),
            .closed,
        ])
        let bridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: session))

        let response = try await bridge.perform(method: "GET", path: "/")

        #expect(response.statusCode == 200)
        #expect(response.body == Data("<h1>House finances</h1>".utf8))

        let sent = try #require(String(data: await session.sentBytes, encoding: .utf8))
        #expect(sent == "GET / HTTP/1.1\r\nHost: clawsite.local\r\nConnection: close\r\n\r\n")
    }

    @Test func reassemblesResponseSplitAcrossFrames() async throws {
        // The tunnel fragments on its own boundaries, which have nothing to do
        // with HTTP structure — a header can land split across two frames.
        let whole = Self.okResponse("hello world")
        let cut = whole.index(whole.startIndex, offsetBy: 12)
        let session = ScriptedClawSiteSession(frames: [
            .data(Data(whole[whole.startIndex..<cut])),
            .data(Data(whole[cut...])),
            .closed,
        ])
        let bridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: session))

        let response = try await bridge.perform(method: "GET", path: "/")
        #expect(response.statusCode == 200)
        #expect(response.body == Data("hello world".utf8))
    }

    @Test func treatsCloseWithoutBytesAsFailure() async throws {
        // A silent close is not an empty 200 — surfacing it as one would render
        // a blank page and hide a broken backend.
        let session = ScriptedClawSiteSession(frames: [.closed])
        let bridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: session))

        await #expect(throws: ClawSiteBridgeError.streamEndedBeforeResponse) {
            _ = try await bridge.perform(method: "GET", path: "/")
        }
    }

    @Test func propagatesStreamFailure() async throws {
        let session = ScriptedClawSiteSession(frames: [.failed("relay-stream-clawsite-not-configured")])
        let bridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: session))

        await #expect(throws: ClawSiteBridgeError.streamFailed("relay-stream-clawsite-not-configured")) {
            _ = try await bridge.perform(method: "GET", path: "/")
        }
    }

    @Test func propagatesOpenFailure() async throws {
        let bridge = ClawSiteHTTPBridge(opener: FailingOpener())
        await #expect(throws: ClawSiteBridgeError.streamFailed("dial refused")) {
            _ = try await bridge.perform(method: "GET", path: "/")
        }
    }

    @Test func enforcesResponseSizeCeiling() async throws {
        let session = ScriptedClawSiteSession(frames: [
            .data(Data(repeating: 0x41, count: 512)),
            .closed,
        ])
        let bridge = ClawSiteHTTPBridge(
            opener: ScriptedOpener(session: session),
            maxResponseBytes: 128
        )

        await #expect(throws: ClawSiteBridgeError.responseTooLarge(limit: 128)) {
            _ = try await bridge.perform(method: "GET", path: "/")
        }
    }

    @Test func timesOutWhenBackendNeverResponds() async throws {
        let bridge = ClawSiteHTTPBridge(
            opener: HangingOpener(),
            timeout: .milliseconds(150)
        )
        await #expect(throws: ClawSiteBridgeError.timedOut) {
            _ = try await bridge.perform(method: "GET", path: "/")
        }
    }

    @Test func closesTheStreamOnSuccessAndOnFailure() async throws {
        let ok = ScriptedClawSiteSession(frames: [.data(Self.okResponse("x")), .closed])
        _ = try await ClawSiteHTTPBridge(opener: ScriptedOpener(session: ok))
            .perform(method: "GET", path: "/")
        #expect(await ok.closeCount == 1)

        // A failed subresource must not leak its tunnel — a page with many
        // broken assets would otherwise pile up live sessions on the owner.
        let bad = ScriptedClawSiteSession(frames: [.failed("boom")])
        _ = try? await ClawSiteHTTPBridge(opener: ScriptedOpener(session: bad))
            .perform(method: "GET", path: "/")
        #expect(await bad.closeCount == 1)
    }

    @Test func completesWithoutAClosedFrameWhenContentLengthIsSatisfied() async throws {
        // The scenario `OpenPersistent` exists for: a target reused across
        // exchanges may sit on a backend with no reason to close after one
        // response, so the bridge must recognize completion without it.
        let session = ScriptedClawSiteSession(frames: [.data(Self.okResponse("no eof needed"))])
        let bridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: session))

        let response = try await bridge.perform(method: "GET", path: "/")
        #expect(response.body == Data("no eof needed".utf8))
        // Proactively closed once the response was recognized as complete —
        // not because the target itself signaled it was done.
        #expect(await session.closeCount == 1)

        // A second exchange must still work cleanly — nothing from the first
        // one (buffered bytes, close state) leaks into it. Each `perform`
        // gets its own scripted session here because the bridge asks its
        // opener for one stream per exchange either way (see
        // `ClawSiteStreamOpening`'s doc): whether that stream is a fresh dial
        // or, per `ClawSiteRelayStreamOpener`, the next target on one reused
        // persistent session is the opener's decision, invisible here.
        let secondSession = ScriptedClawSiteSession(frames: [.data(Self.okResponse("second"))])
        let secondBridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: secondSession))
        let secondResponse = try await secondBridge.perform(method: "GET", path: "/")
        #expect(secondResponse.body == Data("second".utf8))
        #expect(await secondSession.closeCount == 1)
    }

    @Test func closedBeforeCompletionIsNowAFailureNotACompletionSignal() async throws {
        // Inverse of the test above: `.closed` arriving before Content-Length
        // says the response is done is a real failure. The old behavior
        // (any `.closed` ends the response) would have silently returned a
        // truncated body here instead.
        let session = ScriptedClawSiteSession(frames: [
            .data(Data("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\ntoo short".utf8)),
            .closed,
        ])
        let bridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: session))
        await #expect(
            throws: ClawSiteBridgeError.streamFailed("target closed before the response was fully framed")
        ) {
            _ = try await bridge.perform(method: "GET", path: "/")
        }
    }

    @Test func opensOneStreamPerRequestFromTheBridgesPerspective() async throws {
        // The bridge always asks its opener for exactly one stream per
        // exchange. Whether that stream is a fresh dial or the next target on
        // one reused persistent session is the opener's decision — see
        // `ClawSiteRelayStreamOpener`, which does the latter.
        let counter = OpenCounter()
        for _ in 0..<3 {
            let session = ScriptedClawSiteSession(frames: [.data(Self.okResponse("x")), .closed])
            let bridge = ClawSiteHTTPBridge(
                opener: ScriptedOpener(session: session, onOpen: { counter.bump() })
            )
            _ = try await bridge.perform(method: "GET", path: "/")
        }
        #expect(counter.value == 3)
    }

    @Test func forwardsMethodPathHeadersAndBody() async throws {
        let session = ScriptedClawSiteSession(frames: [.data(Self.okResponse("ok")), .closed])
        let bridge = ClawSiteHTTPBridge(opener: ScriptedOpener(session: session), host: "app.internal")

        _ = try await bridge.perform(
            method: "POST",
            path: "/api/save?id=7",
            headers: ["Accept": "application/json"],
            body: Data("{\"a\":1}".utf8)
        )

        let sent = try #require(String(data: await session.sentBytes, encoding: .utf8))
        #expect(sent.hasPrefix("POST /api/save?id=7 HTTP/1.1\r\n"))
        #expect(sent.contains("Host: app.internal\r\n"))
        #expect(sent.contains("Accept: application/json\r\n"))
        #expect(sent.contains("Content-Length: 7\r\n"))
        #expect(sent.hasSuffix("{\"a\":1}"))
    }
}

private final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
