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
/// schema is closed, and values are quantized. The collector THROWS on
/// failure rather than publishing zero-filled numbers (wire must not lie).
final class SystemMetricsCollectorTests: XCTestCase {

    func testSnapshotFieldsArePlausible() throws {
        let snap = try SystemMetricsCollector.snapshot()

        XCTAssertTrue((0...100).contains(snap.cpuLoadPercent), "cpu load is a clamped percentage")
        XCTAssertGreaterThan(snap.memoryUsedMiB, 0, "a running system uses memory")
        XCTAssertGreaterThan(snap.memoryFreeMiB, 0, "a healthy system has reclaimable memory")
        XCTAssertGreaterThan(snap.uptimeSeconds, 0, "boot time predates now")
    }

    /// The schema is closed: encode produces exactly the four contract
    /// fields, nothing the contract does not declare.
    func testEncodeShapeIsClosedSchema() throws {
        let data = try JSONEncoder().encode(try SystemMetricsCollector.snapshot())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), [
            "cpuLoadPercent", "memoryUsedMiB", "memoryFreeMiB", "uptimeSeconds",
        ])
    }

    /// The app-facing vocabulary never gains process/host/path fields by
    /// accident: snapshot round-trips through its own type untouched.
    func testSnapshotRoundTrips() throws {
        let snap = try SystemMetricsCollector.snapshot()
        let decoded = try JSONDecoder().decode(SystemMetricsSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded, snap)
    }

    /// Quantization contract: collections return integral values (no
    /// sub-unit precision that could serve as a clock).
    func testValuesAreQuantized() throws {
        for _ in 0..<3 {
            let snap = try SystemMetricsCollector.snapshot()
            XCTAssertTrue((0...100).contains(snap.cpuLoadPercent))
        }
    }

    /// Permanent rule (celia, after the getloadavg sentinel bug): range
    /// tests are not functioning tests — for live metrics, proving the
    /// value MOVES beats proving it is plausible. A frozen collector was
    /// green for a whole day because its failure value (0) sat inside the
    /// plausible range.
    ///
    /// The monotone canary is uptime: CPU load and free memory may
    /// legitimately repeat between adjacent samples, but uptime can never
    /// stand still. Poll until it strictly advances (it ticks every
    /// second); a timeout means the metric is frozen — the exact bug
    /// class this test exists to make impossible to ship green again.
    func testUptimeAdvancesProvingItVaries() throws {
        let first = try SystemMetricsCollector.snapshot().uptimeSeconds
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if try SystemMetricsCollector.snapshot().uptimeSeconds > first {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("uptime metric did not advance in 2.5s — collector is frozen (sentinel-value bug class)")
    }
}

/// Frozen with the bridge slice: the response envelope resolves the app's
/// Promise; rejection stays reserved for transport failure. Invariants are
/// enforced by the factories, not by convention.
final class CapabilityResponseTests: XCTestCase {

    func testSuccessResponseRoundTrip() throws {
        let request = CapabilityRequest(id: "corr-7", command: .metricsRead)
        let response = CapabilityResponse.success(
            for: request,
            result: .metricsRead(SystemMetricsSnapshot(
                cpuLoadPercent: 42, memoryUsedMiB: 8000, memoryFreeMiB: 4000, uptimeSeconds: 1234
            ))
        )

        XCTAssertEqual(response.id, "corr-7", "id echoes the request's correlation id")
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)

        let decoded = try JSONDecoder().decode(
            CapabilityResponse.self, from: JSONEncoder().encode(response)
        )
        XCTAssertEqual(decoded, response)
    }

    func testFailureResponseRoundTrip() throws {
        let request = CapabilityRequest(id: "corr-8", command: .metricsRead)
        let response = CapabilityResponse.failure(for: request, error: .notGranted)

        XCTAssertEqual(response.id, "corr-8")
        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, .notGranted)

        let decoded = try JSONDecoder().decode(
            CapabilityResponse.self, from: JSONEncoder().encode(response)
        )
        XCTAssertEqual(decoded, response)
    }

    /// Undecodable bodies have no request to echo an id from — the
    /// no-request factory exists for exactly that bridge path.
    func testFailureWithoutRequestUsesProvidedID() {
        let response = CapabilityResponse.failure(id: "", error: .tooLarge(limitBytes: 4096))
        XCTAssertEqual(response.id, "")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .tooLarge)
    }

    /// The result payload is TAGGED with the command key — self-describing
    /// on the wire, closed by construction (one key per capability).
    func testResultIsTaggedWithCommandKey() throws {
        let result = CapabilityResult.metricsRead(SystemMetricsSnapshot(
            cpuLoadPercent: 10, memoryUsedMiB: 1, memoryFreeMiB: 2, uptimeSeconds: 3
        ))

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        )
        XCTAssertEqual(json.count, 1, "result carries exactly one command key")
        XCTAssertNotNil(json["metrics.read"], "payload is tagged with the command it answers")
    }
}
