import XCTest
@testable import VPXStudio

final class VideoInputHealthTests: XCTestCase {
    func testMissingInput() {
        XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: nil), .missing)
    }

    func testTimeoutAndRecovery() {
        XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: 0.5), .active)
        XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: 0.501), .stale)
        XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: 0.01), .active)
    }

    func testRejectsInvalidClockAndLostQuality() {
        for age in [Double.nan, .infinity, -1] {
            XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: age), .stale)
        }
        XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: 0, qualityLost: true), .stale)
    }
}
