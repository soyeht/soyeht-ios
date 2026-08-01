import Foundation

/// One inbound frame of a ClawSite byte stream, reduced to the three outcomes
/// an HTTP exchange cares about.
///
/// The relay-stream data plane emits a wider frame vocabulary (window, health,
/// exit codes — all shaped for a PTY). Collapsing it here keeps the HTTP layer
/// from growing terminal concepts it has no meaning for, and forces the
/// adapter that owns the real session to make an explicit decision about every
/// frame kind rather than silently ignoring one that should have ended the
/// response.
public enum ClawSiteStreamFrame: Sendable, Equatable {
    case data(Data)
    /// The peer finished the response and closed. For ClawSite this is the
    /// authoritative end-of-body signal, because the request asks for
    /// `Connection: close`.
    case closed
    case failed(String)
}

/// A single request/response byte stream to a shared claw's HTTP backend.
public protocol ClawSiteStreamSession: Sendable {
    func send(_ data: Data) async throws
    func nextFrame() async throws -> ClawSiteStreamFrame
    func close() async throws
}

/// Opens a fresh stream per HTTP exchange.
///
/// Deliberately one session per request. The relay's replay guard is keyed on
/// the per-dial auth nonce (freshly minted on every `prepare`), not on the
/// offer, so re-dialing the same offer is expected and safe — while the slot
/// itself was already consumed once, at claim time. Reusing a single long-lived
/// stream instead would mean multiplexing HTTP over a transport with no request
/// framing, which is precisely what `Connection: close` avoids.
public protocol ClawSiteStreamOpening: Sendable {
    func openClawSiteStream() async throws -> any ClawSiteStreamSession
}

public enum ClawSiteBridgeError: Error, Equatable, Sendable {
    case streamFailed(String)
    case streamEndedBeforeResponse
    case responseTooLarge(limit: Int)
    case timedOut
}

/// Performs HTTP exchanges against a shared claw over the relay-stream tunnel.
///
/// This is the piece that was missing: the engine could already serve a claw's
/// HTTP backend over an authenticated tunnel (proven end-to-end with
/// `friend-cli`), and the iOS app already had a web view to render it in, but
/// nothing connected the two — the guest simply had no way to speak HTTP over
/// the stream.
public struct ClawSiteHTTPBridge: Sendable {
    /// Ceiling on a single response. A shared app is someone else's code; an
    /// unbounded read would let it exhaust the phone's memory. 32 MiB is far
    /// above any plausible page or asset and far below a problem.
    public static let defaultMaxResponseBytes = 32 * 1024 * 1024

    /// Wall-clock ceiling for one exchange, so a claw that accepts the stream
    /// and then goes quiet surfaces as an error instead of a spinner.
    public static let defaultTimeout: Duration = .seconds(30)

    private let opener: any ClawSiteStreamOpening
    private let host: String
    private let maxResponseBytes: Int
    private let timeout: Duration

    public init(
        opener: any ClawSiteStreamOpening,
        host: String = "clawsite.local",
        maxResponseBytes: Int = ClawSiteHTTPBridge.defaultMaxResponseBytes,
        timeout: Duration = ClawSiteHTTPBridge.defaultTimeout
    ) {
        self.opener = opener
        self.host = host
        self.maxResponseBytes = maxResponseBytes
        self.timeout = timeout
    }

    public func perform(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> ClawSiteHTTPCodec.Response {
        let requestBytes = try ClawSiteHTTPCodec.serializeRequest(
            method: method,
            path: path,
            host: host,
            headers: headers,
            body: body
        )

        return try await withThrowingTaskGroup(of: ClawSiteHTTPCodec.Response.self) { group in
            group.addTask {
                try await exchange(requestBytes: requestBytes)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ClawSiteBridgeError.timedOut
            }
            guard let first = try await group.next() else {
                throw ClawSiteBridgeError.streamEndedBeforeResponse
            }
            group.cancelAll()
            return first
        }
    }

    private func exchange(requestBytes: Data) async throws -> ClawSiteHTTPCodec.Response {
        let session = try await opener.openClawSiteStream()
        // The stream is closed on every exit path, including the throwing ones:
        // leaking a live tunnel per failed subresource would pile up sessions
        // against the owner's engine.
        do {
            let response = try await run(session: session, requestBytes: requestBytes)
            try? await session.close()
            return response
        } catch {
            try? await session.close()
            throw error
        }
    }

    private func run(
        session: any ClawSiteStreamSession,
        requestBytes: Data
    ) async throws -> ClawSiteHTTPCodec.Response {
        try await session.send(requestBytes)

        var accumulated = Data()
        while true {
            let frame = try await session.nextFrame()
            switch frame {
            case .data(let chunk):
                accumulated.append(chunk)
                guard accumulated.count <= maxResponseBytes else {
                    throw ClawSiteBridgeError.responseTooLarge(limit: maxResponseBytes)
                }
            case .closed:
                guard !accumulated.isEmpty else {
                    throw ClawSiteBridgeError.streamEndedBeforeResponse
                }
                return try ClawSiteHTTPCodec.parseResponse(accumulated)
            case .failed(let reason):
                throw ClawSiteBridgeError.streamFailed(reason)
            }
        }
    }
}
