import Foundation
import Testing

@testable import SoyehtCore

@Suite struct GuestImagePrepareClientTests {
    @MainActor
    @Test func prepareForwardsEndpointAndForce() async throws {
        final class Box: @unchecked Sendable { var value: (URL, Bool)? }
        let box = Box()
        let client = GuestImagePrepareClient(prepareRequest: { url, force in
            box.value = (url, force)
            return GuestImagePrepareResponse(
                v: 1, status: "starting", guestImagePhase: "download_ipsw",
                guestImageStatus: "in_progress", guestImageError: nil, guestImageFailureCode: nil
            )
        })
        let url = URL(string: "http://mac-alpha.example:8091")!
        let response = try await client.prepare(endpoint: url, force: true)
        #expect(box.value?.0 == url)
        #expect(box.value?.1 == true)
        #expect(response.status == "starting")
    }

    @Test func responseDecodesSnakeCaseAndFailureCode() throws {
        let json = Data("""
        {"v":1,"status":"failed","guest_image_phase":"create_disk","guest_image_status":"failed",\
        "guest_image_error":"boom","guest_image_failure_code":"host_vm_limit_reached"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(GuestImagePrepareResponse.self, from: json)
        #expect(response.status == "failed")
        #expect(response.guestImageError == "boom")
        #expect(response.guestImageFailureCode == .hostVmLimitReached)
    }

    @Test func responseFailSoftDecodesUnknownFutureCode() throws {
        let json = Data(#"{"v":1,"status":"failed","guest_image_failure_code":"some_future_code"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(GuestImagePrepareResponse.self, from: json)
        #expect(response.guestImageFailureCode == .unknown)
    }
}
