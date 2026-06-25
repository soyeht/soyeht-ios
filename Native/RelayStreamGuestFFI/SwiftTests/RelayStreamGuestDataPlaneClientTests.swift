import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(description: message)
    }
}

private final class CapturingSigner: RelayStreamGuestSigning, @unchecked Sendable {
    private let signature: Data
    private(set) var signedMessages: [Data] = []

    init(signature: Data) {
        self.signature = signature
    }

    func signRelayStreamAuth(_ bytes: Data) async throws -> Data {
        signedMessages.append(bytes)
        return signature
    }
}

private struct ConnectCall: Equatable {
    let offerCbor: Data
    let expectedOwnerPub: Data
    let expectedGuestPub: Data
    let request: RelayStreamAuthSigningRequest
    let signature: Data
    let nowUnix: UInt64
    let connectTimeoutMs: UInt64
}

private final class FakeNativeAPI: RelayStreamGuestNativeAPI, @unchecked Sendable {
    let request: RelayStreamAuthSigningRequest
    let session: FakeSession
    private(set) var preparedInputs: [RelayStreamPrepareAuthInput] = []
    private(set) var connectCalls: [ConnectCall] = []

    init(request: RelayStreamAuthSigningRequest, session: FakeSession) {
        self.request = request
        self.session = session
    }

    func prepareAuthSigningRequest(
        input: RelayStreamPrepareAuthInput
    ) throws -> RelayStreamAuthSigningRequest {
        preparedInputs.append(input)
        return request
    }

    func connect(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol {
        connectCalls.append(
            ConnectCall(
                offerCbor: offerCbor,
                expectedOwnerPub: expectedOwnerPub,
                expectedGuestPub: expectedGuestPub,
                request: request,
                signature: signature,
                nowUnix: nowUnix,
                connectTimeoutMs: connectTimeoutMs
            )
        )
        return session
    }
}

private final class FakeSession: RelayStreamGuestSessionProtocol, @unchecked Sendable {
    private(set) var sentData: [Data] = []
    private(set) var resizes: [(UInt16, UInt16)] = []
    private(set) var closeCount = 0
    var frames: [RelayStreamGuestFrameRecord]

    init(frames: [RelayStreamGuestFrameRecord] = []) {
        self.frames = frames
    }

    func readFrame() async throws -> RelayStreamGuestFrameRecord {
        if frames.isEmpty {
            throw TestFailure(description: "expected queued frame")
        }
        return frames.removeFirst()
    }

    func sendClose() async throws {
        closeCount += 1
    }

    func sendData(data: Data) async throws {
        sentData.append(data)
    }

    func sendResize(cols: UInt16, rows: UInt16) async throws {
        resizes.append((cols, rows))
    }
}

private func makeRequest(signingBytes: Data) -> RelayStreamAuthSigningRequest {
    RelayStreamAuthSigningRequest(
        authMode: .deviceCredential,
        signingBytes: signingBytes,
        sessionId: "session-alpha",
        endpoint: "relay-stream://192.0.2.10:443",
        targetId: "claw-alpha",
        expiresAt: 1_800_000_060,
        nonce: Data(repeating: 0x44, count: 16),
        authMaterialCbor: Data([0xA1, 0x01, 0x02]),
        guestDevicePub: Data(repeating: 0x03, count: 65)
    )
}

private func testConnectSignsPreparedBytesAndPinsSignatureToNativeConnect() async throws {
    let request = makeRequest(signingBytes: Data([0x10, 0x11, 0x12]))
    let session = FakeSession()
    let native = FakeNativeAPI(request: request, session: session)
    let signer = CapturingSigner(signature: Data(repeating: 0xA5, count: 64))
    let client = RelayStreamGuestDataPlaneClient(native: native)

    let result = try await client.connect(
        offerCbor: Data([0xA1, 0x64]),
        credentialCbor: Data([0xA2, 0x65]),
        expectedOwnerPub: Data(repeating: 0x01, count: 65),
        expectedGuestPub: Data(repeating: 0x02, count: 65),
        nowUnix: 1_800_000_000,
        ttlSecs: 60,
        sessionId: "session-alpha",
        signer: signer,
        connectTimeoutMs: 5_000
    )

    try expect(native.preparedInputs.count == 1, "prepare called once")
    let input = native.preparedInputs[0]
    try expect(input.offerCbor == Data([0xA1, 0x64]), "offer forwarded")
    try expect(input.credentialCbor == Data([0xA2, 0x65]), "credential forwarded")
    try expect(input.expectedOwnerPub == Data(repeating: 0x01, count: 65), "owner pub forwarded")
    try expect(input.expectedGuestPub == Data(repeating: 0x02, count: 65), "guest pub forwarded")
    try expect(input.nowUnix == 1_800_000_000, "now forwarded")
    try expect(input.ttlSecs == 60, "ttl forwarded")
    try expect(input.sessionId == "session-alpha", "session id forwarded")
    try expect(input.nonce == nil, "production nonce left to Rust")

    try expect(signer.signedMessages == [request.signingBytes], "signer saw prepared bytes only")
    try expect(native.connectCalls.count == 1, "connect called once")
    let call = native.connectCalls[0]
    try expect(call.request == request, "prepared request used for connect")
    try expect(call.signature == Data(repeating: 0xA5, count: 64), "raw signature forwarded")
    try expect(call.nowUnix == 1_800_000_000, "connect now forwarded")
    try expect(call.connectTimeoutMs == 5_000, "timeout forwarded")
    try expect(result.native === session, "wrapped returned session")
}

private func testSessionForwardsFrameOperations() async throws {
    let frame = RelayStreamGuestFrameRecord(
        kind: .data,
        data: Data("ACK".utf8),
        number: 0,
        text: ""
    )
    let fake = FakeSession(frames: [frame])
    let session = RelayStreamGuestDataPlaneSession(native: fake)

    try await session.send(data: Data("ping".utf8))
    try await session.resize(cols: 100, rows: 32)
    let received = try await session.nextFrame()
    try await session.close()

    try expect(fake.sentData == [Data("ping".utf8)], "data forwarded")
    try expect(fake.resizes.count == 1, "resize forwarded")
    try expect(fake.resizes[0].0 == 100 && fake.resizes[0].1 == 32, "resize dimensions forwarded")
    try expect(received == frame, "frame returned")
    try expect(fake.closeCount == 1, "close forwarded")
}

@main
private enum RelayStreamGuestDataPlaneClientTestRunner {
    static func main() async throws {
        try await testConnectSignsPreparedBytesAndPinsSignatureToNativeConnect()
        try await testSessionForwardsFrameOperations()
        print("RelayStreamGuestDataPlaneClientTests: 2 passed")
    }
}
