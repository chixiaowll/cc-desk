import XCTest
@testable import CCDeskCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(CCDeskCore.version, "0.1.0")
    }
}
