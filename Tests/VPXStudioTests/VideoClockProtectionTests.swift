import XCTest
import VPXCaptureProtocol
@testable import VPXStudio

final class VideoClockProtectionTests: XCTestCase {
    func testClockExpiryRecoveryAndReconnectResetAreNodeLocal() {
        let a = CaptureNodeHEVCVideoSource(hello: .init(nodeID: UUID(), displayName: "A", capabilities: [.video]))
        let b = CaptureNodeHEVCVideoSource(hello: .init(nodeID: UUID(), displayName: "B", capabilities: [.video]))
        let stats = CaptureClockStatistics(nodeClockOffsetNanoseconds: 100, roundTripNanoseconds: 20,
                                           jitterNanoseconds: 2, acceptedSampleCount: 1)
        XCTAssertFalse(a.hasCurrentClock(at: 100))
        a.updateClockModel(stats, acceptedAtNanoseconds: 100)
        XCTAssertTrue(a.hasCurrentClock(at: 3_000_000_100))
        XCTAssertFalse(a.hasCurrentClock(at: 3_000_000_101))
        XCTAssertFalse(b.hasCurrentClock(at: 100))
        a.updateClockModel(stats, acceptedAtNanoseconds: 4_000_000_000)
        XCTAssertTrue(a.hasCurrentClock(at: 4_000_000_001))
        a.resetClockModel()
        XCTAssertFalse(a.hasCurrentClock(at: 4_000_000_001))
    }
}
