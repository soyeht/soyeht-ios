import XCTest
@testable import SoyehtCore

final class TailnetAddressResolverTests: XCTestCase {
    // MARK: - In-range addresses

    func test_parseTailnetRange_lowerBoundary_isInRange() {
        XCTAssertTrue(TailnetAddressResolver.isTailnetIPv4("100.64.0.1"))
    }

    func test_parseTailnetRange_lowerBoundaryExact_isInRange() {
        XCTAssertTrue(TailnetAddressResolver.isTailnetIPv4("100.64.0.0"))
    }

    func test_parseTailnetRange_upperBoundary_isInRange() {
        XCTAssertTrue(TailnetAddressResolver.isTailnetIPv4("100.127.255.254"))
    }

    func test_parseTailnetRange_upperBoundaryExact_isInRange() {
        XCTAssertTrue(TailnetAddressResolver.isTailnetIPv4("100.127.255.255"))
    }

    // MARK: - Out-of-range addresses

    func test_parseTailnetRange_justAboveUpperBoundary_isOutOfRange() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("100.128.0.0"))
    }

    func test_parseTailnetRange_justBelowLowerBoundary_isOutOfRange() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("100.63.255.255"))
    }

    func test_parseTailnetRange_privateLAN_isOutOfRange() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("192.168.1.1"))
    }

    func test_parseTailnetRange_wrongFirstOctet_isOutOfRange() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("99.64.0.1"))
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("101.64.0.1"))
    }

    // MARK: - Malformed input

    func test_parseTailnetRange_emptyString_isRejected() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4(""))
    }

    func test_parseTailnetRange_wrongOctetCount_isRejected() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("100.64.0"))
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("100.64.0.1.5"))
    }

    func test_parseTailnetRange_nonNumericOctet_isRejected() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("100.64.0.abc"))
    }

    func test_parseTailnetRange_octetOutOfByteRange_isRejected() {
        XCTAssertFalse(TailnetAddressResolver.isTailnetIPv4("100.64.0.256"))
    }
}
