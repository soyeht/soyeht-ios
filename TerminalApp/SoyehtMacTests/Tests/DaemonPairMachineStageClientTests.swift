import CryptoKit
import Foundation
import XCTest
@testable import SoyehtMacDomain
import SoyehtCore

final class DaemonPairMachineStageClientTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    func test_stagePostsTailscaleAndDecodesCBORResult() async throws {
        let recorder = RequestRecorder()
        let uri = try Self.validPairMachineURI(transport: .tailscale)
        let client = DaemonPairMachineStageClient(
            baseURL: URL(string: "http://localhost:8091")!,
            transport: { request in
                await recorder.append(request)
                return try Self.response(
                    status: 200,
                    body: Self.successBody(uri: uri.absoluteString, fingerprint: "abc123def456"),
                    contentType: "application/cbor"
                )
            },
            now: { Self.now }
        )

        let result = try await client.stage()
        let capturedRequest = await recorder.requests.first

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.path, "/bootstrap/pair-machine/local/stage")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/cbor")
        XCTAssertEqual(try Self.transportField(from: capturedRequest?.httpBody), "tailscale")
        XCTAssertEqual(result.pairMachineURI, uri)
        XCTAssertEqual(result.fingerprint, "abc123def456")
        XCTAssertEqual(result.ttlUnix, UInt64(Self.now.timeIntervalSince1970 + 300))
        XCTAssertEqual(result.transportUsed, .tailscale)
        XCTAssertFalse(result.fellBackFromTailscale)
    }

    func test_stageAcceptsNonCanonicalCBORMapOrder() async throws {
        let uri = try Self.validPairMachineURI(transport: .tailscale)
        let client = DaemonPairMachineStageClient(
            baseURL: URL(string: "http://localhost:8091")!,
            transport: { _ in
                try Self.response(
                    status: 200,
                    body: Self.successBodyWithWireOrder(uri: uri.absoluteString, fingerprint: "wire123"),
                    contentType: "application/cbor"
                )
            },
            now: { Self.now }
        )

        let result = try await client.stage()

        XCTAssertEqual(result.pairMachineURI, uri)
        XCTAssertEqual(result.fingerprint, "wire123")
    }

    func test_stageFallsBackToLANWhenTailscaleHasNoAddress() async throws {
        let recorder = RequestRecorder()
        let lanURI = try Self.validPairMachineURI(transport: .lan)
        let client = DaemonPairMachineStageClient(
            baseURL: URL(string: "http://localhost:8091")!,
            transport: { request in
                let transport = try Self.transportField(from: request.httpBody)
                await recorder.append(request)
                if transport == "tailscale" {
                    return try Self.response(
                        status: 500,
                        body: Self.noTransportBody(transport: "Tailscale"),
                        contentType: "application/cbor"
                    )
                }
                return try Self.response(
                    status: 200,
                    body: Self.successBody(uri: lanURI.absoluteString, fingerprint: "lan123"),
                    contentType: "application/cbor"
                )
            },
            now: { Self.now }
        )

        let result = try await client.stage()
        let transports = try await recorder.requests.map { try Self.transportField(from: $0.httpBody) }

        XCTAssertEqual(transports, ["tailscale", "lan"])
        XCTAssertEqual(result.pairMachineURI, lanURI)
        XCTAssertEqual(result.transportUsed, .lan)
        XCTAssertTrue(result.fellBackFromTailscale)
    }

    private actor RequestRecorder {
        private(set) var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            requests.append(request)
        }
    }

    func test_stageMaps404ToEndpointUnavailable() async {
        let client = DaemonPairMachineStageClient(
            baseURL: URL(string: "http://localhost:8091")!,
            transport: { _ in
                try Self.response(status: 404, body: Data(), contentType: "text/plain")
            },
            now: { Self.now }
        )

        do {
            _ = try await client.stage()
            XCTFail("Expected endpointUnavailable")
        } catch let error as DaemonPairMachineStageError {
            XCTAssertEqual(error, .endpointUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_stageMapsAlreadyPairedState() async {
        let client = DaemonPairMachineStageClient(
            baseURL: URL(string: "http://localhost:8091")!,
            transport: { _ in
                try Self.response(
                    status: 409,
                    body: HouseholdCBOR.encode(.map([
                        "v": .unsigned(1),
                        "error": .text("household_already_paired"),
                        "state": .text("ready"),
                    ])),
                    contentType: "application/cbor"
                )
            },
            now: { Self.now }
        )

        do {
            _ = try await client.stage()
            XCTFail("Expected alreadyPaired")
        } catch let error as DaemonPairMachineStageError {
            XCTAssertEqual(error, .alreadyPaired(state: "ready"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func successBody(uri: String, fingerprint: String) -> Data {
        HouseholdCBOR.encode(.map([
            "pair_machine_uri": .text(uri),
            "fingerprint": .text(fingerprint),
            "ttl_unix": .unsigned(UInt64(now.timeIntervalSince1970 + 300)),
        ]))
    }

    private static func successBodyWithWireOrder(uri: String, fingerprint: String) -> Data {
        var data = Data([0xA3])
        data.append(HouseholdCBOR.encode(.text("ttl_unix")))
        data.append(HouseholdCBOR.encode(.unsigned(UInt64(now.timeIntervalSince1970 + 300))))
        data.append(HouseholdCBOR.encode(.text("pair_machine_uri")))
        data.append(HouseholdCBOR.encode(.text(uri)))
        data.append(HouseholdCBOR.encode(.text("fingerprint")))
        data.append(HouseholdCBOR.encode(.text(fingerprint)))
        return data
    }

    private static func noTransportBody(transport: String) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "error": .text("no_transport_address"),
            "transport": .text(transport),
            "reason": .text("no \(transport) interface address available"),
        ]))
    }

    private static func response(
        status: Int,
        body: Data,
        contentType: String
    ) throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:8091/bootstrap/pair-machine/local/stage")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        return (body, response)
    }

    private static func transportField(from body: Data?) throws -> String {
        let data = try XCTUnwrap(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["transport"] as? String)
    }

    private static func validPairMachineURI(transport: PairMachineStageTransport) throws -> URL {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let nonce = Data(repeating: 0xAB, count: 32)
        let publicKey = privateKey.publicKey.compressedRepresentation
        let platform = PairMachinePlatform.macos.rawValue
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: publicKey,
            nonce: nonce,
            hostname: "studio.local",
            platform: platform
        )
        let signature = try privateKey.signature(for: challenge).rawRepresentation
        let ttlUnix = Int(now.addingTimeInterval(300).timeIntervalSince1970)

        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-machine"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "m_pub", value: publicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: nonce.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "hostname", value: "studio.local"),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "transport", value: transport.rawValue),
            URLQueryItem(name: "addr", value: transport == .tailscale ? "100.64.1.5:8091" : "192.168.1.20:8091"),
            URLQueryItem(name: "challenge_sig", value: signature.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(ttlUnix)),
            URLQueryItem(name: "anchor_secret", value: Data(repeating: 0xCC, count: 32).soyehtBase64URLEncodedString()),
        ]
        return try XCTUnwrap(components.url)
    }
}
