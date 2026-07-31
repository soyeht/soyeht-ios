import Foundation
import Testing

@testable import SoyehtCore

struct RosterSignerPinClientTests {
    private final class SigningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var payload: Data? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ d: Data) { lock.lock(); stored = d; lock.unlock() }
    }

    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        let box: SigningBox
        func sign(_ payload: Data) throws -> Data {
            box.set(payload)
            return Data(repeating: 0x11, count: 64)
        }
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ r: URLRequest) { lock.lock(); stored = r; lock.unlock() }
    }

    private let nonce = Data(repeating: 0xAA, count: 32)

    private func makeClient(
        status: Int,
        responseBody: Data,
        contentType: String? = "application/cbor",
        box: RequestBox? = nil,
        signingBox: SigningBox = SigningBox()
    ) -> RosterSignerPinClient {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(box: signingBox),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return RosterSignerPinClient(
            baseURL: URL(string: "http://192.0.2.10:8101")!,
            popSigner: signer,
            perform: { req in
                box?.set(req)
                var headers: [String: String] = [:]
                if let contentType { headers["Content-Type"] = contentType }
                let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (responseBody, resp)
            }
        )
    }

    private func successBody(nonce: Data) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data([0x01, 0x02])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
    }

    @Test func rejects31ByteNonceBeforeTransport() async {
        let box = RequestBox()
        let client = makeClient(status: 200, responseBody: successBody(nonce: nonce), box: box)
        await #expect(throws: RosterSignerPinClientError.wire(.malformedResponse)) {
            _ = try await client.signerPin(clientNonce: Data(repeating: 0xAA, count: 31))
        }
        #expect(box.request == nil)
    }

    @Test func rejects33ByteNonceBeforeTransport() async {
        let box = RequestBox()
        let client = makeClient(status: 200, responseBody: successBody(nonce: nonce), box: box)
        await #expect(throws: RosterSignerPinClientError.wire(.malformedResponse)) {
            _ = try await client.signerPin(clientNonce: Data(repeating: 0xAA, count: 33))
        }
        #expect(box.request == nil)
    }

    @Test func popSignsExactSigningContext() async throws {
        let box = RequestBox()
        let signingBox = SigningBox()
        let client = makeClient(status: 200, responseBody: successBody(nonce: nonce), box: box, signingBox: signingBox)
        _ = try await client.signerPin(clientNonce: nonce)
        let req = box.request
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path == "/api/v1/household/roster/signer-pin")
        #expect(try req?.httpBody == RosterWire.encodeNonceRequest(clientNonce: nonce))
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(req?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        let expected = HouseholdCBOR.requestSigningContext(
            method: "POST",
            pathAndQuery: "/api/v1/household/roster/signer-pin",
            timestamp: 1_800_000_000,
            bodyHash: HouseholdHash.blake3(try RosterWire.encodeNonceRequest(clientNonce: nonce))
        )
        #expect(signingBox.payload == expected)
    }

    @Test func decodesExact7Keys() async throws {
        let client = makeClient(status: 200, responseBody: successBody(nonce: nonce))
        let response = try await client.signerPin(clientNonce: nonce)
        #expect(response.v == 1)
        #expect(response.clientNonce == nonce)
        #expect(response.hhId == "hh_test")
        #expect(response.mId == "m_aaa")
        #expect(response.machineCert == Data([0x01, 0x02]))
        #expect(response.machineCertFingerprint == Data(repeating: 0x0A, count: 32))
        #expect(response.signature == Data(repeating: 0x0E, count: 64))
    }

    @Test func rejectsWrongVersion() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(2),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data([0x01])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterSignerPinClientError.wire(.malformedResponse)) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsEmptyMachineCert() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data()),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterSignerPinClientError.wire(.malformedResponse)) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsNullRequiredField() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .null,
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data([0x01])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsBadFingerprintLength() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data([0x01])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 16)),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsBadSignatureLength() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data([0x01])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "signature": .bytes(Data(repeating: 0x0E, count: 32)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsExtraKey() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data([0x01])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
            "extra": .text("x"),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsMissingKey() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .text("m_aaa"),
            "machine_cert": .bytes(Data([0x01])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsWrongTypeForMId() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "client_nonce": .bytes(nonce),
            "hh_id": .text("hh_test"),
            "m_id": .unsigned(7),
            "machine_cert": .bytes(Data([0x01])),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func rejectsWrongResponseContentType() async {
        let client = makeClient(status: 200, responseBody: successBody(nonce: nonce), contentType: "application/json")
        await #expect(throws: RosterWireError.unsupportedContentType) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }

    @Test func mapsStatusToLiteral() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("unauthenticated")]))
        let client = makeClient(status: 401, responseBody: body)
        await #expect(throws: RosterSignerPinClientError.wire(.serverError(code: "unauthenticated"))) {
            _ = try await client.signerPin(clientNonce: nonce)
        }
    }
}
