import Foundation

public protocol RelayStreamGuestSigning: Sendable {
    func signRelayStreamAuth(_ bytes: Data) async throws -> Data
}

public protocol RelayStreamGuestNativeAPI: Sendable {
    func prepareAuthSigningRequest(
        input: RelayStreamPrepareAuthInput
    ) throws -> RelayStreamAuthSigningRequest

    func connect(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol

    /// Same handshake as `connect`, but negotiates `OpenPersistent` for the
    /// first target so the returned session's `openNextTarget()` can reuse
    /// this Noise connection for further targets. See
    /// `relay_stream_connect_persistent`'s Rust doc for the wire-contract
    /// provenance.
    func connectPersistent(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol
}

public struct UniFFIRelayStreamGuestNativeAPI: RelayStreamGuestNativeAPI {
    public init() {}

    public func prepareAuthSigningRequest(
        input: RelayStreamPrepareAuthInput
    ) throws -> RelayStreamAuthSigningRequest {
        try relayStreamPrepareAuthSigningRequest(input: input)
    }

    public func connect(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol {
        try await relayStreamConnect(
            offerCbor: offerCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            request: request,
            signature: signature,
            nowUnix: nowUnix,
            connectTimeoutMs: connectTimeoutMs
        )
    }

    public func connectPersistent(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol {
        try await relayStreamConnectPersistent(
            offerCbor: offerCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            request: request,
            signature: signature,
            nowUnix: nowUnix,
            connectTimeoutMs: connectTimeoutMs
        )
    }
}

public struct RelayStreamGuestDataPlaneClient: Sendable {
    public let native: any RelayStreamGuestNativeAPI

    public init(native: any RelayStreamGuestNativeAPI = UniFFIRelayStreamGuestNativeAPI()) {
        self.native = native
    }

    public func prepareAuthSigningRequest(
        offerCbor: Data,
        credentialCbor: Data?,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        nowUnix: UInt64,
        ttlSecs: UInt64,
        sessionId: String,
        nonce: Data? = nil
    ) throws -> RelayStreamAuthSigningRequest {
        try native.prepareAuthSigningRequest(
            input: RelayStreamPrepareAuthInput(
                offerCbor: offerCbor,
                credentialCbor: credentialCbor,
                expectedOwnerPub: expectedOwnerPub,
                expectedGuestPub: expectedGuestPub,
                nowUnix: nowUnix,
                ttlSecs: ttlSecs,
                sessionId: sessionId,
                nonce: nonce
            )
        )
    }

    public func connectPrepared(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> RelayStreamGuestDataPlaneSession {
        let session = try await native.connect(
            offerCbor: offerCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            request: request,
            signature: signature,
            nowUnix: nowUnix,
            connectTimeoutMs: connectTimeoutMs
        )
        return RelayStreamGuestDataPlaneSession(native: session)
    }

    public func connect(
        offerCbor: Data,
        credentialCbor: Data?,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        nowUnix: UInt64,
        ttlSecs: UInt64,
        sessionId: String,
        signer: any RelayStreamGuestSigning,
        connectTimeoutMs: UInt64
    ) async throws -> RelayStreamGuestDataPlaneSession {
        let request = try prepareAuthSigningRequest(
            offerCbor: offerCbor,
            credentialCbor: credentialCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            nowUnix: nowUnix,
            ttlSecs: ttlSecs,
            sessionId: sessionId
        )
        let signature = try await signer.signRelayStreamAuth(request.signingBytes)
        return try await connectPrepared(
            offerCbor: offerCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            request: request,
            signature: signature,
            nowUnix: nowUnix,
            connectTimeoutMs: connectTimeoutMs
        )
    }

    public func connectPersistentPrepared(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> RelayStreamGuestDataPlaneSession {
        let session = try await native.connectPersistent(
            offerCbor: offerCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            request: request,
            signature: signature,
            nowUnix: nowUnix,
            connectTimeoutMs: connectTimeoutMs
        )
        return RelayStreamGuestDataPlaneSession(native: session)
    }

    /// Same as `connect`, but the returned session negotiated `OpenPersistent`
    /// for its first target and can `openNextTarget()` to reuse the same
    /// Noise connection for further targets instead of dialing again.
    public func connectPersistent(
        offerCbor: Data,
        credentialCbor: Data?,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        nowUnix: UInt64,
        ttlSecs: UInt64,
        sessionId: String,
        signer: any RelayStreamGuestSigning,
        connectTimeoutMs: UInt64
    ) async throws -> RelayStreamGuestDataPlaneSession {
        let request = try prepareAuthSigningRequest(
            offerCbor: offerCbor,
            credentialCbor: credentialCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            nowUnix: nowUnix,
            ttlSecs: ttlSecs,
            sessionId: sessionId
        )
        let signature = try await signer.signRelayStreamAuth(request.signingBytes)
        return try await connectPersistentPrepared(
            offerCbor: offerCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            request: request,
            signature: signature,
            nowUnix: nowUnix,
            connectTimeoutMs: connectTimeoutMs
        )
    }
}

public struct RelayStreamGuestDataPlaneSession: Sendable {
    public let native: any RelayStreamGuestSessionProtocol

    public init(native: any RelayStreamGuestSessionProtocol) {
        self.native = native
    }

    public func send(data: Data) async throws {
        try await native.sendData(data: data)
    }

    public func resize(cols: UInt16, rows: UInt16) async throws {
        try await native.sendResize(cols: cols, rows: rows)
    }

    /// Closes only the current target, not the whole session. Only meaningful
    /// on a session opened via `connectPersistent`/`connectPersistentPrepared`
    /// — call `openNextTarget()` afterward to reuse the same Noise connection
    /// for another target, rather than dialing again.
    public func close() async throws {
        try await native.sendClose()
    }

    /// Reuse this session's already-authenticated Noise connection for the
    /// next target. Only valid after `close()` on the current one; only valid
    /// on a session opened via `connectPersistent`/`connectPersistentPrepared`
    /// (the underlying `OpenPersistent` request is rejected server-side
    /// otherwise). Unlike an earlier version of this API, the call already
    /// drains and validates the server's ack internally before returning —
    /// a rejection surfaces as a thrown Swift error from this call, not as
    /// an `.error` frame to read via `nextFrame()`. A caller that returns
    /// successfully can go straight to reading real target data; see the
    /// Rust `open_next_target` doc for why there is no per-target signing
    /// here.
    public func openNextTarget() async throws {
        try await native.openNextTarget()
    }

    public func metadata() async -> RelayStreamGuestSessionMetadata {
        await native.metadata()
    }

    public func nextFrame() async throws -> RelayStreamGuestFrameRecord {
        try await native.readFrame()
    }
}
