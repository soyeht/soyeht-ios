import Foundation
import XCTest
@testable import SoyehtCore

// Slice 3A: the final, atomic add-Mac join step (`POST
// /bootstrap/accept-household/confirm`) must run the same `EngineCompat`
// pre-flight as the initialize / accept-household clients — failing with a
// typed `BootstrapError.engineTooOld` BEFORE the confirm POST is ever sent,
// so an incompatible engine cannot commit a half-understood membership.
final class BootstrapAcceptHouseholdConfirmClientTests: XCTestCase {
    private static let baseURL = URL(string: "http://127.0.0.1:8091")!

    func test_confirm_failsEngineTooOld_withoutSendingConfirmRequest() async {
        let spy = PathSpy()
        let oldStatus = makeStatusCBOR(engineVersion: "0.0.1")
        let client = BootstrapAcceptHouseholdConfirmClient(
            baseURL: Self.baseURL,
            transport: { request in
                let path = request.url?.path ?? ""
                spy.record(path)
                if path == BootstrapStatusClient.path {
                    return (oldStatus, makeCBORResponse(path: path))
                }
                // Reaching here means the gate failed to stop the POST.
                return (Data(), makeCBORResponse(path: path))
            }
        )

        do {
            _ = try await client.confirm(
                machineId: "m_test",
                machineCert: Data([0x01, 0x02, 0x03]),
                challengeSig: Data(repeating: 0x07, count: 64)
            )
            XCTFail("expected engineTooOld")
        } catch BootstrapError.engineTooOld(let found, let required) {
            XCTAssertEqual(found, "0.0.1")
            XCTAssertEqual(required, EngineCompat.minSupportedEngineVersion)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(
            spy.hit(BootstrapStatusClient.path),
            "compat pre-flight must query /bootstrap/status"
        )
        XCTAssertFalse(
            spy.hit(BootstrapAcceptHouseholdConfirmClient.path),
            "confirm POST must NOT be sent when the engine is too old"
        )
    }

    func test_confirm_passesCompatPreflight_thenDecodesResponse_onSupportedEngine() async throws {
        let spy = PathSpy()
        let status = makeStatusCBOR(engineVersion: EngineCompat.minSupportedEngineVersion)
        let confirmResponse = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "bootstrap_state": .text("ready"),
            "m_id": .text("m_test"),
            "hh_id": .text("hh_test"),
        ]))
        let client = BootstrapAcceptHouseholdConfirmClient(
            baseURL: Self.baseURL,
            transport: { request in
                let path = request.url?.path ?? ""
                spy.record(path)
                if path == BootstrapStatusClient.path {
                    return (status, makeCBORResponse(path: path))
                }
                return (confirmResponse, makeCBORResponse(path: path))
            }
        )

        let result = try await client.confirm(
            machineId: "m_test",
            machineCert: Data([0x01, 0x02, 0x03]),
            challengeSig: Data(repeating: 0x07, count: 64)
        )

        XCTAssertEqual(result.bootstrapState, "ready")
        XCTAssertEqual(result.machineId, "m_test")
        XCTAssertEqual(result.householdId, "hh_test")
        XCTAssertTrue(spy.hit(BootstrapStatusClient.path), "pre-flight must query status first")
        XCTAssertTrue(
            spy.hit(BootstrapAcceptHouseholdConfirmClient.path),
            "confirm POST must be sent once compat passes"
        )
    }
}

// MARK: - Helpers

private final class PathSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        paths.append(path)
    }
    func hit(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.contains(path)
    }
}

private func makeCBORResponse(path: String) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:8091\(path)")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/cbor"]
    )!
}

/// Minimal valid `/bootstrap/status` CBOR with a custom `engine_version`.
/// Mirrors the proven shape in `EngineCompatTests`; only `engine_version`
/// matters to the compat gate.
private func makeStatusCBOR(engineVersion: String) -> Data {
    HouseholdCBOR.encode(.map([
        "v": .unsigned(1),
        "state": .text("uninitialized"),
        "engine_version": .text(engineVersion),
        "platform": .text("mac"),
        "host_label": .text("Mac"),
        "device_count": .unsigned(0),
        "owner_display_name": .null,
        "hh_id": .null,
        "hh_pub": .null,
    ]))
}
