import XCTest
@testable import VPXStudio

final class ClockFreshnessTests: XCTestCase {
    func testUnmeasuredAndExpiry() {
        XCTAssertEqual(ClockFreshness.evaluate(lastAccepted: nil, now: 10), .unmeasured)
        XCTAssertEqual(ClockFreshness.evaluate(lastAccepted: 100, now: 3_000_000_100), .current)
        XCTAssertEqual(ClockFreshness.evaluate(lastAccepted: 100, now: 3_000_000_101), .stale)
        XCTAssertEqual(ClockFreshness.evaluate(lastAccepted: 100, now: 99), .stale)
        XCTAssertEqual(ClockFreshness.evaluate(lastAccepted: 4_000_000_000, now: 4_000_000_001), .current)
    }
}
