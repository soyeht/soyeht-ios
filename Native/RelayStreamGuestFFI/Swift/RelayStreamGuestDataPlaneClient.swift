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
}

public struct RelayStreamGuestDataPlaneClient: Sendable {
    public let native: any RelayStreamGuestNativeAPI

    public init(native: any RelayStreamGuestNativeAPI = UniFFIRelayStreamGuestNativeAPI()) {
        self.native = native
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
        let request = try native.prepareAuthSigningRequest(
            input: RelayStreamPrepareAuthInput(
                offerCbor: offerCbor,
                credentialCbor: credentialCbor,
                expectedOwnerPub: expectedOwnerPub,
                expectedGuestPub: expectedGuestPub,
                nowUnix: nowUnix,
                ttlSecs: ttlSecs,
                sessionId: sessionId,
                nonce: nil
            )
        )
        let signature = try await signer.signRelayStreamAuth(request.signingBytes)
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

    public func close() async throws {
        try await native.sendClose()
    }

    public func nextFrame() async throws -> RelayStreamGuestFrameRecord {
        try await native.readFrame()
    }
}
