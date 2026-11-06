import XCTest
@testable import VPXStudio

final class PoseHealthTests: XCTestCase {
    func testExpiryDespiteHealthyClock() {
        let pose = PoseHealth(lastAcceptedNanoseconds: 100, quality: .nominal)
        XCTAssertEqual(pose.effectiveQuality(now: 500_000_100, clock: .current), .nominal)
        XCTAssertEqual(pose.effectiveQuality(now: 500_000_101, clock: .current), .lost)
    }

    func testMissingClockAndReversedTimeAreLost() {
        XCTAssertEqual(PoseHealth().effectiveQuality(now: 100, clock: .current), .lost)
        let pose = PoseHealth(lastAcceptedNanoseconds: 100, quality: .nominal)
        XCTAssertEqual(pose.effectiveQuality(now: 101, clock: .stale), .lost)
        XCTAssertEqual(pose.effectiveQuality(now: 101, clock: .unmeasured), .lost)
        XCTAssertEqual(pose.effectiveQuality(now: 99, clock: .current), .lost)
    }

    func testNodeIsolationAndRecovery() {
        var a = PoseHealth(lastAcceptedNanoseconds: 0, quality: .nominal)
        let b = PoseHealth(lastAcceptedNanoseconds: 600_000_000, quality: .degraded)
        XCTAssertEqual(a.effectiveQuality(now: 600_000_001, clock: .current), .lost)
        XCTAssertEqual(b.effectiveQuality(now: 600_000_001, clock: .current), .degraded)
        a = PoseHealth(lastAcceptedNanoseconds: 600_000_001, quality: .estimated)
        XCTAssertEqual(a.effectiveQuality(now: 600_000_002, clock: .current), .estimated)
    }
}
