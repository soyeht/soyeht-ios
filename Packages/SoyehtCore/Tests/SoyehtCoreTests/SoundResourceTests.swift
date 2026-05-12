import XCTest
@testable import SoyehtCore

final class SoundResourceTests: XCTestCase {
    func test_onboardingSoundAssets_areBundled() {
        XCTAssertNotNil(SoundDirector.resourceURL(for: .houseCreated))
        XCTAssertNotNil(SoundDirector.resourceURL(for: .residentPaired))
    }
}
