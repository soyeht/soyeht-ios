import Foundation
import Testing
@testable import SoyehtCore

private final class PairingPollFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // Each URL chooses its own response; parallel cases share no handler.
        let variant = request.url!.pathComponents[1]
        let status = variant == "wrong-status" ? 503 : 404
        let body: String
        switch variant {
        case "missing-route": body = "Not Found"
        case "unknown-code": body = #"{"v":1,"code":"future_error"}"#
        case "unknown-schema": body = #"{"v":2,"code":"device_pairing_request_not_found"}"#
        default: body = #"{"v":1,"error":"device_pairing_request_not_found","code":"device_pairing_request_not_found"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct DevicePairingPollFailureTests {
    @Test(arguments: ["lost-request", "missing-route", "unknown-code", "unknown-schema", "wrong-status"])
    func pollDistinguishesAnUnavailableRequestFromOtherFailures(variant: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingPollFailureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionHouseholdDevicePairingHTTPClient(session: session)
        let endpoint = URL(string: "http://pairing.example.test/\(variant)")!
        do {
            _ = try await client.pollPairing(endpoint: endpoint, requestId: "request-example", token: "TOKEN_EXAMPLE")
            Issue.record("The refused poll must not become an approved session")
        } catch let failure as PairingAttemptFailure {
            #expect(failure.stage == .poll)
            #expect(failure.cause == (variant == "lost-request"
                ? .approvalRequestUnavailable : .server(status: variant == "wrong-status" ? 503 : 404)))
            #expect(failure.endpoint?.query == nil)
            #expect(!failure.diagnostic.contains("TOKEN_EXAMPLE"))
            if variant == "lost-request" {
                #expect(!failure.userMessage.contains("declined"))
            }
        }
    }

    @Test func theSame404DuringIssuanceIsNotALostPendingRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingPollFailureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionHouseholdDevicePairingHTTPClient(session: session)
        do {
            _ = try await client.requestPairing(endpoint: URL(string: "http://pairing.example.test/lost-request")!,
                devicePublicKey: Data(repeating: 1, count: 33), deviceName: "Test iPhone", platform: "ios")
            Issue.record("The rejected request must fail")
        } catch let failure as PairingAttemptFailure {
            #expect(failure.stage == .request)
            #expect(failure.cause == .server(status: 404))
        }
    }
}
