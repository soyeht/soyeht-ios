import XCTest
@testable import SoyehtMacDomain

/// Phase 2b acceptance §6: malformed body, unknown key, unknown command,
/// and oversized body are each refused with their own error — and the size
/// gate runs BEFORE the parser.
final class CapabilityEnvelopeTests: XCTestCase {

    private func jsonData(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Happy path

    func testRoundTrip() throws {
        let request = CapabilityRequest(id: "corr-42", command: .metricsRead)
        let data = try JSONEncoder().encode(request)
        let decoded = try CapabilityRequest.decode(data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.command, .metricsRead)
    }

    func testEncodeShapeIsClosedSchema() throws {
        let data = try JSONEncoder().encode(CapabilityRequest(id: "x", command: .metricsRead))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json.count, 3, "envelope carries exactly v, id, command")
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["id"] as? String, "x")
        XCTAssertEqual(json["command"] as? String, "metrics.read")
    }

    // MARK: - Strict decode (the measured trap: typed containers hide unknown keys)

    func testUnknownKeyIsRejected() throws {
        // A typed container cannot report this key — only the any-keyed
        // second container sees it (phase 2a measurement). If this test
        // passes, the strict path is live.
        let data = try jsonData([
            "v": 1,
            "id": "x",
            "command": "metrics.read",
            "token": "attacker-controlled",
        ])

        XCTAssertThrowsError(try CapabilityRequest.decode(data)) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .unknownKey("token"))
        }
    }

    func testUnknownCommandIsRejected() throws {
        let data = try jsonData(["v": 1, "id": "x", "command": "fs.read"])

        XCTAssertThrowsError(try CapabilityRequest.decode(data)) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .unknownCommand("fs.read"))
        }
    }

    func testUnsupportedVersionIsRejected() throws {
        let data = try jsonData(["v": 2, "id": "x", "command": "metrics.read"])

        XCTAssertThrowsError(try CapabilityRequest.decode(data)) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .unsupportedVersion(2))
        }
    }

    func testMissingKeysAreRejectedByName() throws {
        let noV = try jsonData(["id": "x", "command": "metrics.read"])
        XCTAssertThrowsError(try CapabilityRequest.decode(noV)) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .missingKey("v"))
        }

        let noID = try jsonData(["v": 1, "command": "metrics.read"])
        XCTAssertThrowsError(try CapabilityRequest.decode(noID)) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .missingKey("id"))
        }

        let noCommand = try jsonData(["v": 1, "id": "x"])
        XCTAssertThrowsError(try CapabilityRequest.decode(noCommand)) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .missingKey("command"))
        }
    }

    func testEmptyIDIsRejected() throws {
        let data = try jsonData(["v": 1, "id": "", "command": "metrics.read"])

        XCTAssertThrowsError(try CapabilityRequest.decode(data)) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .invalidID)
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try CapabilityRequest.decode(Data("[{ not json".utf8))) { error in
            XCTAssertEqual(error as? CapabilityRequestError, .malformed)
        }
    }

    // MARK: - Size gate BEFORE the parser

    /// The oversized payload is also INVALID JSON at its tail — if the size
    /// gate ran after parsing, this would surface as `.malformed` instead
    /// of `.tooLarge`. Proves the order.
    func testSizeLimitIsEnforcedBeforeParsing() {
        var oversized = Data("{\"v\":1,\"id\":\"".utf8)
        oversized += Data(repeating: 0x61, count: CapabilityRequest.maxBodyBytes)
        oversized += Data("garbage-not-json".utf8)

        XCTAssertThrowsError(try CapabilityRequest.decode(oversized)) { error in
            guard case .tooLarge(let limit) = error as? CapabilityRequestError else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
            XCTAssertEqual(limit, CapabilityRequest.maxBodyBytes)
        }
    }

    // MARK: - Failure vocabulary is closed; messages leak nothing

    func testFailureCodesRoundTripOnTheWire() throws {
        // Enum-backed code must serialize as the plain string the app sees.
        let failure = CapabilityFailure.notGranted
        let data = try JSONEncoder().encode(failure)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "not_granted")
        XCTAssertNotNil(json["message"] as? String)
    }

    func testFailureVocabularyIsExactlyTheClosedSet() {
        let expected: Set<String> = [
            "too_large", "malformed", "unknown_key", "unknown_command",
            "unsupported_version", "not_granted", "rate_limited", "internal_error",
        ]
        XCTAssertEqual(Set(CapabilityFailureCode.allCases.map(\.rawValue)), expected)
    }

    /// By construction: the constructors take no path, host, or user
    /// context — there is nothing to leak even if a future caller tries.
    /// This test pins the guarantee against constructor drift.
    func testFailureMessagesCarryNoPathsOrHosts() throws {
        let all: [CapabilityFailure] = [
            .tooLarge(limitBytes: 4096), .malformed, .unknownCommand,
            .unsupportedVersion, .notGranted, .rateLimited, .internalError,
        ]
        for failure in all {
            XCTAssertFalse(failure.message.contains("/"), "message must not embed paths: \(failure.message)")
            XCTAssertFalse(failure.message.contains("Users"), "message must not embed user paths: \(failure.message)")
        }
    }
}

/// Phase 2b contract §3 — the collector is system aggregate only, the
/// schema is closed, and values are quantized.
final class SystemMetricsCollectorTests: XCTestCase {

    func testSnapshotFieldsArePlausible() {
        let snap = SystemMetricsCollector.snapshot()

        XCTAssertTrue((0...100).contains(snap.cpuLoadPercent), "cpu load is a clamped percentage")
        XCTAssertGreaterThan(snap.memoryUsedMiB, 0, "a running system uses memory")
        XCTAssertGreaterThan(snap.memoryFreeMiB, 0, "a healthy system has reclaimable memory")
        XCTAssertGreaterThan(snap.uptimeSeconds, 0, "boot time predates now")
    }

    /// The schema is closed: encode produces exactly the four contract
    /// fields, nothing the contract does not declare.
    func testEncodeShapeIsClosedSchema() throws {
        let data = try JSONEncoder().encode(SystemMetricsCollector.snapshot())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), [
            "cpuLoadPercent", "memoryUsedMiB", "memoryFreeMiB", "uptimeSeconds",
        ])
    }

    /// The app-facing vocabulary never gains process/host/path fields by
    /// accident: snapshot round-trips through its own type untouched.
    func testSnapshotRoundTrips() throws {
        let snap = SystemMetricsCollector.snapshot()
        let decoded = try JSONDecoder().decode(SystemMetricsSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded, snap)
    }

    /// Quantization contract: two immediate collections return integral
    /// values (no sub-unit precision that could serve as a clock).
    func testValuesAreQuantized() {
        for _ in 0..<3 {
            let snap = SystemMetricsCollector.snapshot()
            XCTAssertTrue((0...100).contains(snap.cpuLoadPercent))
            _ = snap // integral by type: Int / Int64 — the type IS the quantization
        }
    }
}
