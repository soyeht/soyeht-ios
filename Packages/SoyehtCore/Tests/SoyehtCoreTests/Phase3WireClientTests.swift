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

    // MARK: - Wrong-type axis (PR #53 deferred F3)
    //
    // Each test below ships a CBOR error envelope where one field's CBOR
    // *major type* is wrong (text instead of unsigned, unsigned instead
    // of text, bytes instead of text). The decoder relies on
    // `case .unsigned`/`case .text` pattern matches, so a wrong-type
    // value silently fails the match and falls through to a typed error
    // — the tests pin the exact error case so a future relaxation of
    // the decoder (e.g. accepting `.text("1")` for `v`) is caught.

    @Test func versionFieldWithTextTypeSurfacesMissingErrorVersion() async throws {
        // `v: text("1")` — wrong major type even though the textual
        // value parses to "1". The decoder's `case .unsigned` match
        // fails and we surface `missingErrorVersion`. This is the
        // contract anchor: peers MUST emit `v` as a CBOR unsigned
        // integer; sending it as a text-coded string is a wire-format
        // violation.
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map([
            "v": .text("1"),
            "error": .text("expired"),
        ]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected missingErrorVersion")
        } catch Phase3WireError.missingErrorVersion {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func versionFieldWithBytesTypeSurfacesMissingErrorVersion() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map([
            "v": .bytes(Data([0x01])),
            "error": .text("expired"),
        ]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected missingErrorVersion")
        } catch Phase3WireError.missingErrorVersion {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func errorFieldWithUnsignedTypeSurfacesMissingErrorField() async throws {
        // `error: unsigned(7)` — peers MUST emit `error` as a text
        // code. A numeric error code is a contract regression we
        // surface as `missingErrorField` rather than coerce.
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "error": .unsigned(7),
        ]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected missingErrorField")
        } catch Phase3WireError.missingErrorField {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func errorFieldWithBytesTypeSurfacesMissingErrorField() async throws {
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "error": .bytes(Data("expired".utf8)),
        ]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected missingErrorField")
        } catch Phase3WireError.missingErrorField {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func messageFieldWithBytesTypeIsTreatedAsAbsent() async throws {
        // Pins current behaviour: when the optional `message` field has
        // the wrong major type, the decoder silently treats it as
        // absent and surfaces `statusError(message: nil)`. This is
        // tolerant rather than fail-closed because `message` is
        // explicitly optional in the contract — but a regression that
        // begins surfacing the bytes verbatim (e.g. base64-coercing)
        // would change the operator-visible string and is caught here.
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "error": .text("expired"),
            "message": .bytes(Data("not a string".utf8)),
        ]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected statusError")
        } catch Phase3WireError.statusError(let httpStatus, let code, let message) {
            #expect(httpStatus == 410)
            #expect(code == "expired")
            #expect(message == nil)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func errorEnvelopeAtTopLevelArrayShapeSurfacesMalformed() async throws {
        // The error envelope MUST be a CBOR map. An array at the top
        // level is a wire-shape violation, not a missing field.
        let store = RequestStore()
        let body = HouseholdCBOR.encode(.array([
            .unsigned(1),
            .text("expired"),
        ]))
        let client = Self.client(capturing: store, respondWith: body, status: 410)

        do {
            _ = try await client.send(method: "POST", url: Self.endpoint, body: Data([0xA0]))
            Issue.record("Expected malformedErrorBody")
        } catch Phase3WireError.malformedErrorBody {
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
