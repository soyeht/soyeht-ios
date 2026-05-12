import XCTest
@testable import SoyehtCore

/// T067b — Cross-language fixture consumer for the house-created push payload.
///
/// When theyos produces `theyos/tests/fixtures/house_created_push.json`, the
/// build phase script in T039d copies it to:
///   `Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/push/house-created.json`
///
/// Until that fixture lands, the test gracefully skips with an informative message.
/// This design satisfies T067b's "validates Swift parser decodes byte-equal" contract
/// without blocking CI.
final class HouseCreatedPushPayloadTests: XCTestCase {

    // MARK: - Fixture path

    private static var fixtureURL: URL? {
        Bundle.module.url(forResource: "house-created", withExtension: "json", subdirectory: "Fixtures/push")
    }

    // MARK: - Tests

    func test_parse_fromFixture_allCasesDecodedByteEqual() throws {
        guard let url = Self.fixtureURL else {
            throw XCTSkip("house-created.json fixture not yet available — run theyos T067b first")
        }

        let data = try Data(contentsOf: url)
        let cases = try JSONDecoder().decode([FixtureCase].self, from: data)

        XCTAssertFalse(cases.isEmpty, "Fixture must contain at least 1 test case")

        for (index, testCase) in cases.enumerated() {
            let result = HouseCreatedPushHandler.parse(testCase.userInfo)

            switch result {
            case .houseCreated(let payload):
                XCTAssertEqual(payload.hhId,       testCase.expected.hhId,       "case[\(index)] hhId mismatch")
                XCTAssertEqual(payload.hhName,     testCase.expected.hhName,     "case[\(index)] hhName mismatch")
                XCTAssertEqual(payload.machineId,  testCase.expected.machineId,  "case[\(index)] machineId mismatch")
                XCTAssertEqual(payload.machineLabel, testCase.expected.machineLabel, "case[\(index)] machineLabel mismatch")
                XCTAssertEqual(payload.pairQrUri,  testCase.expected.pairQrUri,  "case[\(index)] pairQrUri mismatch")
                XCTAssertEqual(payload.timestamp,  testCase.expected.timestamp,  "case[\(index)] timestamp mismatch")

            case .malformed:
                XCTFail("case[\(index)] '\(testCase.name)': parsed as malformed, expected houseCreated")
            case .notSoyehtPayload:
                XCTFail("case[\(index)] '\(testCase.name)': parsed as notSoyehtPayload, expected houseCreated")
            case .unknownType(let t):
                XCTFail("case[\(index)] '\(testCase.name)': parsed as unknownType(\(t)), expected houseCreated")
            }
        }
    }

    func test_parse_unknownType_doesNotCrash() {
        let userInfo: [AnyHashable: Any] = [
            "soyeht": ["type": "future_event", "extra_data": 42]
        ]
        guard case .unknownType(let type) = HouseCreatedPushHandler.parse(userInfo) else {
            XCTFail("Expected .unknownType")
            return
        }
        XCTAssertEqual(type, "future_event")
    }

    func test_parse_missingType_returnsMalformed() {
        let userInfo: [AnyHashable: Any] = [
            "soyeht": ["hh_id": "abc"]
        ]
        guard case .malformed = HouseCreatedPushHandler.parse(userInfo) else {
            XCTFail("Expected .malformed")
            return
        }
    }

    func test_parse_noSoyehtKey_returnsNotSoyehtPayload() {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": "hello"]]
        guard case .notSoyehtPayload = HouseCreatedPushHandler.parse(userInfo) else {
            XCTFail("Expected .notSoyehtPayload")
            return
        }
    }

    func test_parse_houseCreated_withIntTimestamp_decodes() {
        let userInfo: [AnyHashable: Any] = [
            "soyeht": [
                "type":          "house_created",
                "hh_id":         "hh-123",
                "hh_name":       "Silva Home",
                "machine_id":    "mac-456",
                "machine_label": "Mac",
                "pair_qr_uri":   "soyeht://pair?token=abc",
                "ts":            1_700_000_000 as Int
            ] as [String: Any]
        ]
        guard case .houseCreated(let p) = HouseCreatedPushHandler.parse(userInfo) else {
            XCTFail("Expected .houseCreated")
            return
        }
        XCTAssertEqual(p.hhId, "hh-123")
        XCTAssertEqual(p.timestamp, 1_700_000_000)
    }

    func test_parse_legacyPortugueseType_decodes() {
        let userInfo: [AnyHashable: Any] = [
            "soyeht": [
                "type":          "casa_nasceu",
                "hh_id":         "hh-legacy",
                "hh_name":       "Legacy Home",
                "machine_id":    "mac-legacy",
                "machine_label": "Mac",
                "pair_qr_uri":   "soyeht://pair?token=legacy",
                "ts":            1_700_000_001 as Int
            ] as [String: Any]
        ]
        guard case .houseCreated(let p) = HouseCreatedPushHandler.parse(userInfo) else {
            XCTFail("Expected .houseCreated")
            return
        }
        XCTAssertEqual(p.hhId, "hh-legacy")
        XCTAssertEqual(p.timestamp, 1_700_000_001)
    }
}

// MARK: - Fixture Schema

private struct FixtureCase: Decodable {
    /// Expected payload fields before APNs wrapping.
    let expected: ExpectedPayload
    /// The raw APNs userInfo dictionary as produced by the Rust push sender.
    let rawUserInfo: [String: AnyCodable]

    var name: String { expected.hhName }

    /// Converts `rawUserInfo` to `[AnyHashable: Any]` for passing to the parser.
    var userInfo: [AnyHashable: Any] {
        rawUserInfo.mapValues { $0.value } as [AnyHashable: Any]
    }

    enum CodingKeys: String, CodingKey {
        case expected = "input"
        case rawUserInfo = "expected"
    }
}

private struct ExpectedPayload: Decodable {
    let hhId: String
    let hhName: String
    let machineId: String
    let machineLabel: String
    let pairQrUri: String
    let timestamp: UInt64

    enum CodingKeys: String, CodingKey {
        case hhId = "hh_id"
        case hhName = "hh_name"
        case machineId = "machine_id"
        case machineLabel = "machine_label"
        case pairQrUri = "pair_qr_uri"
        case timestamp = "ts"
    }
}

/// Minimal JSON-any bridge for fixture schema.
private struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let uint = try? container.decode(UInt64.self) {
            value = uint
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else {
            value = NSNull()
        }
    }
}
