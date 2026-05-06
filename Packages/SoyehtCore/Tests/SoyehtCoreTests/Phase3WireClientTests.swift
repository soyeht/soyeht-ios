import Foundation
import Testing
@testable import SoyehtCore

@Suite("Phase3WireClient")
struct Phase3WireClientTests {
    private static let endpoint = URL(string: "https://household.example/api/v1/household/owner-events/approve")!

    private static func httpResponse(
        status: Int,
        contentType: String? = "application/cbor"
    ) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType = contentType {
            headers["Content-Type"] = contentType
        }
        return HTTPURLResponse(
            url: endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private static func client(
        capturing requestStore: RequestStore,
        respondWith body: Data,
        status: Int = 200,
        contentType: String? = "application/cbor"
    ) -> Phase3WireClient {
        Phase3WireClient(perform: { request in
            await requestStore.record(request)
            let response = Self.httpResponse(status: status, contentType: contentType)
            return (body, response)
        })
    }

    actor RequestStore {
        private(set) var captured: URLRequest?
        func record(_ request: URLRequest) { captured = request }
    }

    @Test func successResponseReturnsBodyVerbatim() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "ok": .bool(true)]))
        let outbound = HouseholdCBOR.encode(.map(["v": .unsigned(1), "ping": .bool(true)]))
        let client = Self.client(capturing: store, respondWith: body)

        let result = try await client.send(method: "POST", url: Self.endpoint, body: outbound)
        #expect(result == body)

        let captured = await store.captured
        #expect(captured?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(captured?.value(forHTTPHeaderField: "Accept") == "application/cbor")
        #expect(captured?.httpMethod == "POST")
    }

    @Test func sentBodyIsByteIdenticalToCanonicalCBORInput() async throws {
        let store = RequestStore()
        let outbound = HouseholdCBOR.ownerApprovalBody(
            cursor: 7,
            approvalSignature: Data(repeating: 0xAB, count: 64)
        )
        let client = Self.client(
            capturing: store,
            respondWith: HouseholdCBOR.encode(.map(["v": .unsigned(1), "ok": .bool(true)]))
        )

        _ = try await client.send(method: "POST", url: Self.endpoint, body: outbound)

        let captured = await store.captured
        #expect(captured?.httpBody == outbound)
    }

    @Test func cborErrorBodyParsesIntoStatusErrorCase() async throws {
        let store = RequestStore()
        let errorBody = HouseholdCBOR.encode(.map([
            "error": .text("expired"),
            "message": .text("nonce TTL elapsed"),
            "v": .unsigned(1),
        ]))
        let client = Self.client(capturing: store, respondWith: errorBody, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected statusError")
        } catch Phase3WireError.statusError(let status, let code, let message) {
            #expect(status == 410)
            #expect(code == "expired")
            #expect(message == "nonce TTL elapsed")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func errorBodyWithoutMessageStillSurfacesCode() async throws {
        let store = RequestStore()
        let errorBody = HouseholdCBOR.encode(.map([
            "error": .text("forbidden"),
            "v": .unsigned(1),
        ]))
        let client = Self.client(capturing: store, respondWith: errorBody, status: 403)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected statusError(forbidden)")
        } catch Phase3WireError.statusError(_, let code, let message) {
            #expect(code == "forbidden")
            #expect(message == nil)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func jsonContentTypeOnSuccessIsRefused() async throws {
        let store = RequestStore()
        let client = Self.client(
            capturing: store,
            respondWith: Data("{\"ok\":true}".utf8),
            status: 200,
            contentType: "application/json"
        )

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected wrongContentType")
        } catch Phase3WireError.wrongContentType(let returned) {
            #expect(returned == "application/json")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func jsonContentTypeOnErrorIsRefused() async throws {
        let store = RequestStore()
        let client = Self.client(
            capturing: store,
            respondWith: Data("{\"error\":\"x\"}".utf8),
            status: 400,
            contentType: "application/json"
        )

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected wrongContentType")
        } catch Phase3WireError.wrongContentType {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func missingContentTypeIsRefused() async throws {
        let store = RequestStore()
        let client = Self.client(
            capturing: store,
            respondWith: Data([0xA0]),
            contentType: nil
        )

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected wrongContentType(nil)")
        } catch Phase3WireError.wrongContentType(let returned) {
            #expect(returned == nil)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func contentTypeWithCharsetSuffixIsAccepted() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "ok": .bool(true)]))
        let client = Self.client(
            capturing: store,
            respondWith: body,
            contentType: "application/cbor; charset=utf-8"
        )

        let result = try await client.send(method: "POST", url: Self.endpoint, body: body)
        #expect(result == body)
    }

    @Test func malformedCBORErrorBodySurfacesTypedError() async throws {
        let store = RequestStore()
        let client = Self.client(
            capturing: store,
            respondWith: Data([0xFF, 0xFF, 0xFF]),  // not valid CBOR
            status: 500
        )

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected malformedErrorBody")
        } catch Phase3WireError.malformedErrorBody {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func errorBodyMissingVersionFieldSurfacesTypedError() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map(["error": .text("expired")]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected missingErrorVersion")
        } catch Phase3WireError.missingErrorVersion {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func errorBodyMissingErrorFieldSurfacesTypedError() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1)]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected missingErrorField")
        } catch Phase3WireError.missingErrorField {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func unsupportedErrorVersionSurfacesTypedError() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(2),
            "error": .text("future"),
        ]))
        let client = Self.client(capturing: store, respondWith: body, status: 400)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected unsupportedErrorVersion")
        } catch Phase3WireError.unsupportedErrorVersion(let version) {
            #expect(version == 2)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func transportLevelFailureMapsToTransportFailed() async throws {
        struct TransportError: Error {}
        let client = Phase3WireClient(perform: { _ in throw TransportError() })

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected transportFailed")
        } catch Phase3WireError.transportFailed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func additionalHeadersArePropagatedToRequest() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "ok": .bool(true)]))
        let client = Self.client(capturing: store, respondWith: body)

        _ = try await client.send(
            method: "POST",
            url: Self.endpoint,
            body: body,
            additionalHeaders: ["X-Soyeht-PoP": "abc.def"]
        )

        let captured = await store.captured
        #expect(captured?.value(forHTTPHeaderField: "X-Soyeht-PoP") == "abc.def")
    }
}
