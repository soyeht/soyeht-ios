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
        {"v":1,"state":"uninitialized","version":"0.1.8","platform":"macos","host_label":"Mac Studio","uptime_secs":12,"hh_id":null,"device_count":0}
        """.data(using: .utf8)!
        let client = makeClient(response: response, contentType: "application/json")

        let result = try await client.fetch()

        XCTAssertEqual(result.state, .uninitialized)
        XCTAssertEqual(result.engineVersion, "0.1.8")
        XCTAssertEqual(result.platform, "macos")
        XCTAssertEqual(result.hostLabel, "Mac Studio")
        XCTAssertEqual(result.deviceCount, 0)
        XCTAssertNil(result.hhId)
        XCTAssertNil(result.hhPub)
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
            "host_label": .text("Mac Studio"),
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
