import XCTest
@testable import SoyehtMacDomain

@MainActor
final class EngineAttachGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EngineAttachGate.resetForTesting()
    }

    override func tearDown() {
        EngineAttachGate.resetForTesting()
        super.tearDown()
    }

    func test_theSecondAttachOfTheSamePaneIsTurnedAway() {
        let pane = UUID()
        XCTAssertTrue(EngineAttachGate.begin(pane))
        XCTAssertFalse(EngineAttachGate.begin(pane))
        XCTAssertTrue(EngineAttachGate.isInFlight(pane))
    }

    func test_endingReleasesThePaneForTheNextAttach() {
        let pane = UUID()
        XCTAssertTrue(EngineAttachGate.begin(pane))
        EngineAttachGate.end(pane)
        XCTAssertFalse(EngineAttachGate.isInFlight(pane))
        XCTAssertTrue(EngineAttachGate.begin(pane))
    }

    func test_panesDoNotBlockEachOther() {
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(EngineAttachGate.begin(first))
        XCTAssertTrue(EngineAttachGate.begin(second))
        EngineAttachGate.end(first)
        XCTAssertFalse(EngineAttachGate.isInFlight(first))
        XCTAssertTrue(EngineAttachGate.isInFlight(second))
    }

    func test_endingAPaneThatNeverStartedIsHarmless() {
        EngineAttachGate.end(UUID())
        XCTAssertFalse(EngineAttachGate.isInFlight(UUID()))
    }
}
