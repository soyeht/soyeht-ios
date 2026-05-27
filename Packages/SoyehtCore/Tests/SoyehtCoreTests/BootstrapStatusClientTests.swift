import XCTest
@testable import SoyehtCore

final class BootstrapStatusClientTests: XCTestCase {
    // MARK: - State decoding

    func test_decodes_uninitialized() async throws {
        let client = makeClient(response: makeStatusResponse(state: "uninitialized"))
        let result = try await client.fetch()
        XCTAssertEqual(result.state, .uninitialized)
    }

    func test_decodes_readyForNaming() async throws {
        let client = makeClient(response: makeStatusResponse(state: "ready_for_naming"))
        let result = try await client.fetch()
        XCTAssertEqual(result.state, .readyForNaming)
    }

    func test_decodes_namedAwaitingPair() async throws {
        let client = makeClient(response: makeStatusResponse(state: "named_awaiting_pair"))
        let result = try await client.fetch()
        XCTAssertEqual(result.state, .namedAwaitingPair)
    }

    func test_decodes_ready() async throws {
        let client = makeClient(response: makeStatusResponse(state: "ready"))
        let result = try await client.fetch()
        XCTAssertEqual(result.state, .ready)
    }

    func test_decodes_recovering() async throws {
        let client = makeClient(response: makeStatusResponse(state: "recovering"))
        let result = try await client.fetch()
        XCTAssertEqual(result.state, .recovering)
    }

    // MARK: - hh_pub round-trip

    func test_hhPub_roundTrip_33bytes() async throws {
        let pub = Data(repeating: 0x02, count: 33)
        let client = makeClient(response: makeStatusResponse(state: "ready", hhPub: pub))
        let result = try await client.fetch()
        XCTAssertEqual(result.hhPub, pub)
    }

    func test_decodes_jsonStatusFromCurrentEngine() async throws {
        let response = """
        {"v":1,"state":"uninitialized","version":"0.1.8","platform":"macos","host_label":"Mac","uptime_secs":12,"hh_id":null,"device_count":0}
        """.data(using: .utf8)!
        let client = makeClient(response: response, contentType: "application/json")

        let result = try await client.fetch()

        XCTAssertEqual(result.state, .uninitialized)
        XCTAssertEqual(result.engineVersion, "0.1.8")
        XCTAssertEqual(result.platform, "macos")
        XCTAssertEqual(result.hostLabel, "Mac")
        XCTAssertEqual(result.deviceCount, 0)
        XCTAssertNil(result.hhId)
        XCTAssertNil(result.hhPub)
    }

    // MARK: - guest_image_* round-trip (theyos v0.1.19)

    /// CBOR fixture with the v0.1.19 `guest_image_*` fields populated.
    /// All three are additive on the engine side (`skip_serializing_if =
    /// "Option::is_none"`), so pre-v0.1.19 responses omit them entirely
    /// — covered by every test above that doesn't include them.
    func test_decodes_guestImageFields_cborWhenPresent() async throws {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "state": .text("ready"),
            "engine_version": .text("0.1.19"),
            "platform": .text("macos"),
            "host_label": .text("Mac"),
            "device_count": .unsigned(0),
            "owner_display_name": .null,
            "hh_id": .null,
            "hh_pub": .null,
            "guest_image_phase": .text("install_macos"),
            "guest_image_status": .text("in_progress"),
        ]
        map["guest_image_error"] = .null
        let data = HouseholdCBOR.encode(.map(map))
        let client = makeClient(response: data)

        let result = try await client.fetch()

        XCTAssertEqual(result.guestImagePhase, "install_macos")
        XCTAssertEqual(result.guestImageStatus, "in_progress")
        XCTAssertNil(result.guestImageError)
        XCTAssertEqual(result.guestImageReadiness, .inProgress(phase: "install_macos"))
    }

    func test_decodes_guestImageFields_cborWhenAbsent_returnsNil() async throws {
        // A v0.1.18 engine (or a v0.1.19 Linux engine, or a v0.1.19 Mac
        // without init-state.json) omits the three fields entirely.
        // Decoder must accept this and surface nil — `requireKnown`
        // only complains about *unknown* keys, not missing optional
        // ones.
        let client = makeClient(response: makeStatusResponse(state: "ready"))

        let result = try await client.fetch()

        XCTAssertNil(result.guestImagePhase)
        XCTAssertNil(result.guestImageStatus)
        XCTAssertNil(result.guestImageError)
    }

    func test_decodes_guestImageFields_cborWithFailedStatus_carriesError() async throws {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "state": .text("ready"),
            "engine_version": .text("0.1.19"),
            "platform": .text("macos"),
            "host_label": .text("Mac"),
            "device_count": .unsigned(0),
            "owner_display_name": .null,
            "hh_id": .null,
            "hh_pub": .null,
            "guest_image_phase": .text("provision"),
            "guest_image_status": .text("failed"),
            "guest_image_error": .text("provision-inject exit 1"),
        ]
        let data = HouseholdCBOR.encode(.map(map))
        let client = makeClient(response: data)

        let result = try await client.fetch()

        XCTAssertEqual(result.guestImageStatus, "failed")
        XCTAssertEqual(result.guestImageError, "provision-inject exit 1")
        XCTAssertEqual(
            result.guestImageReadiness,
            .failed(error: "provision-inject exit 1"),
            "Failed status must round-trip into structured readiness so the iOS UI gets a recovery hint."
        )
    }

    func test_decodes_guestImageFields_jsonWhenPresent() async throws {
        let response = """
        {"v":1,"state":"ready","version":"0.1.19","platform":"macos","host_label":"Mac","device_count":1,"hh_id":"hh-test","hh_pub":null,"guest_image_phase":"create_snapshot","guest_image_status":"in_progress","guest_image_error":null}
        """.data(using: .utf8)!
        let client = makeClient(response: response, contentType: "application/json")

        let result = try await client.fetch()

        XCTAssertEqual(result.guestImagePhase, "create_snapshot")
        XCTAssertEqual(result.guestImageStatus, "in_progress")
        XCTAssertNil(result.guestImageError)
        XCTAssertEqual(result.guestImageReadiness, .inProgress(phase: "create_snapshot"))
    }

    func test_decodes_guestImageFields_jsonWhenAbsent_returnsNil() async throws {
        // Engine v0.1.18 JSON shape — no guest_image_* fields at all.
        // JSON decoder silently ignores unknown keys, and the synthesised
        // decoder leaves Optional fields as nil when absent.
        let response = """
        {"v":1,"state":"ready","version":"0.1.18","platform":"linux","host_label":"linuxbox","device_count":1,"hh_id":"hh-test","hh_pub":null}
        """.data(using: .utf8)!
        let client = makeClient(response: response, contentType: "application/json")

        let result = try await client.fetch()

        XCTAssertNil(result.guestImagePhase)
        XCTAssertNil(result.guestImageStatus)
        XCTAssertNil(result.guestImageError)
        // Linux + nil ≠ Mac + nil: this engine reports platform=linux so
        // the readiness is .notApplicable (install allowed).
        XCTAssertEqual(result.guestImageReadiness, .notApplicable)
    }

    // MARK: - Unknown state value

    func test_unknownStateValue_throwsProtocolViolation() async {
        let client = makeClient(response: makeStatusResponse(state: "future_state_unknown"))
        do {
            _ = try await client.fetch()
            XCTFail("expected throw")
        } catch BootstrapError.protocolViolation(let detail) {
            if case .unknownStateValue(let v) = detail {
                XCTAssertEqual(v, "future_state_unknown")
            } else {
                XCTFail("wrong violation detail: \(detail)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Non-CBOR content type

    func test_wrongContentType_throwsProtocolViolation() async {
        let client = makeClient(
            response: makeStatusResponse(state: "uninitialized"),
            contentType: "text/plain"
        )
        do {
            _ = try await client.fetch()
            XCTFail("expected throw")
        } catch BootstrapError.protocolViolation(let detail) {
            guard case .wrongContentType = detail else {
                XCTFail("wrong violation detail: \(detail)"); return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - 503 retry schedule

    func test_503engineInitializing_retriesWithBackoff() async throws {
        let recorder = BootstrapStatusTestRecorder()

        let transport: BootstrapStatusClient.TransportPerform = { _ in
            let call = await recorder.nextCall()
            if call <= 2 {
                let errData = HouseholdCBOR.encode(.map([
                    "v": .unsigned(1),
                    "error": .text("engine_initializing"),
                ]))
                return (errData, makeHTTPResponse(statusCode: 503))
            }
            return (Self.makeStatusCBOR(state: "ready_for_naming"), makeHTTPResponse(statusCode: 200))
        }

        let client = BootstrapStatusClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: transport,
            sleeper: { delay in await recorder.appendDelay(delay) }
        )
        let result = try await client.fetch()
        let snapshot = await recorder.snapshot()

        XCTAssertEqual(result.state, .readyForNaming)
        XCTAssertEqual(snapshot.callCount, 3)
        XCTAssertEqual(snapshot.delays.count, 2)
        XCTAssertEqual(snapshot.delays[0], 0.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.delays[1], 1.0, accuracy: 0.01)
    }

    func test_503engineInitializing_exhaustsRetries_throws() async {
        let transport: BootstrapStatusClient.TransportPerform = { _ in
            let errData = HouseholdCBOR.encode(.map([
                "v": .unsigned(1),
                "error": .text("engine_initializing"),
            ]))
            return (errData, makeHTTPResponse(statusCode: 503))
        }
        let client = BootstrapStatusClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: transport,
            sleeper: { _ in }
        )
        do {
            _ = try await client.fetch()
            XCTFail("expected throw")
        } catch BootstrapError.serverError(let code, _) {
            XCTAssertEqual(code, "engine_initializing")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_jsonError_prefersStableCodeOverHumanError() async {
        let recorder = BootstrapStatusTestRecorder()
        let transport: BootstrapStatusClient.TransportPerform = { _ in
            let call = await recorder.nextCall()
            if call == 1 {
                let errData = """
                {"error":"Engine is still starting","code":"engine_initializing","message":"retry later"}
                """.data(using: .utf8)!
                return (errData, makeHTTPResponse(statusCode: 503, contentType: "application/json"))
            }
            return (Self.makeStatusCBOR(state: "ready_for_naming"), makeHTTPResponse(statusCode: 200))
        }
        let client = BootstrapStatusClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: transport,
            sleeper: { _ in }
        )

        do {
            let result = try await client.fetch()
            let snapshot = await recorder.snapshot()
            XCTAssertEqual(result.state, .readyForNaming)
            XCTAssertEqual(snapshot.callCount, 2)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeClient(
        response: Data,
        contentType: String = "application/cbor"
    ) -> BootstrapStatusClient {
        BootstrapStatusClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { _ in (response, makeHTTPResponse(statusCode: 200, contentType: contentType)) },
            sleeper: { _ in }
        )
    }

    private func makeStatusResponse(state: String, hhPub: Data? = nil) -> Data {
        Self.makeStatusCBOR(state: state, hhPub: hhPub)
    }

    static func makeStatusCBOR(state: String, hhPub: Data? = nil) -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "state": .text(state),
            "engine_version": .text("0.1.8"),
            "platform": .text("mac"),
            "host_label": .text("Mac"),
            "device_count": .unsigned(0),
        ]
        map["owner_display_name"] = .null
        map["hh_id"] = .null
        if let pub = hhPub {
            map["hh_pub"] = .bytes(pub)
        } else {
            map["hh_pub"] = .null
        }
        return HouseholdCBOR.encode(.map(map))
    }
}

// MARK: - Test helpers

private func makeHTTPResponse(statusCode: Int, contentType: String = "application/cbor") -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:8091/bootstrap/status")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": contentType]
    )!
}

private actor BootstrapStatusTestRecorder {
    private(set) var callCount = 0
    private(set) var delays: [TimeInterval] = []

    func nextCall() -> Int {
        callCount += 1
        return callCount
    }

    func appendDelay(_ delay: UInt64) {
        delays.append(TimeInterval(delay) / 1_000_000_000)
    }

    func snapshot() -> (callCount: Int, delays: [TimeInterval]) {
        (callCount, delays)
    }
}
