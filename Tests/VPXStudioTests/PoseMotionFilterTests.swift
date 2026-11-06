import XCTest
import simd
import VPXCaptureProtocol
@testable import VPXStudio

final class PoseMotionFilterTests: XCTestCase {
    func pose(_ sequence: UInt64, time: UInt64, x: Float = 0, angle: Float = 0,
              revision: UInt64 = 1, quality: CaptureTrackingQuality = .nominal) -> CapturePosePacket {
        let q = simd_quatf(angle: angle, axis: SIMD3<Float>(0,1,0)).vector
        return .init(sequence: sequence, captureTimeNanoseconds: time, translationMeters: [x,0,0],
            rotationQuaternion: [q.x,q.y,q.z,q.w], linearVelocityMetersPerSecond: [0,0,0],
            angularVelocityRadiansPerSecond: [0,0,0], quality: quality, referenceSpaceRevision: revision)
    }
    func testRejectsTeleportWithoutPoisoningNextBaseline() {
        var filter = PoseMotionFilter()
        XCTAssertNotNil(filter.accept(pose(1, time: 1_000_000_000)))
        XCTAssertNil(filter.accept(pose(2, time: 1_016_000_000, x: 10)))
        XCTAssertEqual(filter.lastRejection, .motion)
        XCTAssertNotNil(filter.accept(pose(3, time: 1_032_000_000, x: 0.1)))
        XCTAssertEqual(filter.rejectedCount, 1)
        XCTAssertEqual(filter.acceptedCount, 2)
        XCTAssertNil(filter.lastRejection)
    }
    func testRotationJumpAndQuaternionSignEquivalence() {
        var filter = PoseMotionFilter()
        XCTAssertNotNil(filter.accept(pose(1, time: 1_000_000_000)))
        XCTAssertNil(filter.accept(pose(2, time: 1_001_000_000, angle: .pi)))
        XCTAssertNotNil(filter.accept(pose(3, time: 1_020_000_000, angle: 2 * .pi)))
    }
    func testGapRequiresThreeConsecutiveConsistentMeasurements() {
        var filter = PoseMotionFilter()
        XCTAssertNotNil(filter.accept(pose(1, time: 1_000_000_000)))
        XCTAssertNil(filter.accept(pose(2, time: 2_000_000_000, x: 10)))
        XCTAssertNil(filter.accept(pose(3, time: 2_020_000_000, x: 10.1)))
        XCTAssertEqual(filter.lastRejection, .reacquiring)
        let recovered = filter.accept(pose(4, time: 2_040_000_000, x: 10.2))
        XCTAssertEqual(recovered?.position.x, 10.2)
        XCTAssertEqual(recovered?.transform.columns.3.x, 10.2)
        // A second gap with an inconsistent candidate must start over.
        XCTAssertNil(filter.accept(pose(5, time: 3_000_000_000, x: 20)))
        XCTAssertNil(filter.accept(pose(6, time: 3_020_000_000, x: 25)))
        XCTAssertNil(filter.accept(pose(7, time: 3_040_000_000, x: 25.1)))
        XCTAssertNotNil(filter.accept(pose(8, time: 3_060_000_000, x: 25.2)))
    }
    func testBadNumbersLostAndReorderingCannotRefreshHealth() {
        var filter = PoseMotionFilter()
        XCTAssertNotNil(filter.accept(pose(10, time: 1_000_000_000)))
        XCTAssertNil(filter.accept(pose(11, time: 1_020_000_000, x: .nan)))
        XCTAssertEqual(filter.lastRejection, .malformed)
        XCTAssertNil(filter.accept(pose(12, time: 1_030_000_000, quality: .lost)))
        XCTAssertEqual(filter.lastRejection, .unavailable)
        XCTAssertNil(filter.accept(pose(9, time: 1_040_000_000)))
        XCTAssertEqual(filter.lastRejection, .reordered)
        XCTAssertNil(filter.accept(pose(13, time: 999_999_999)))
        XCTAssertEqual(filter.acceptedCount, 1)
        let health = PoseHealth(lastAcceptedNanoseconds: 1_000_000_000, quality: .nominal,
                                capturedHostNanoseconds: 1_000_000_000)
        XCTAssertEqual(health.effectiveQuality(now: 1_600_000_000, clock: .current), .lost)
    }
    func testNodeIsolationAndExplicitReferenceChange() {
        var a = PoseMotionFilter(), b = PoseMotionFilter()
        XCTAssertNotNil(a.accept(pose(1, time: 1_000_000_000)))
        XCTAssertNotNil(b.accept(pose(1, time: 1_000_000_000, x: 100)))
        XCTAssertNil(a.accept(pose(2, time: 1_010_000_000, x: 100)))
        XCTAssertNotNil(b.accept(pose(2, time: 1_010_000_000, x: 100.1)))
        XCTAssertNotNil(a.accept(pose(1, time: 10, x: 50, revision: 2)))
        XCTAssertEqual(b.rejectedCount, 0)
    }
    func testNonUnitQuaternionIsRejected() {
        let packet = CapturePosePacket(sequence: 1, captureTimeNanoseconds: 10,
            translationMeters: [0,0,0], rotationQuaternion: [0,0,0,100],
            linearVelocityMetersPerSecond: [0,0,0], angularVelocityRadiansPerSecond: [0,0,0],
            quality: .nominal, referenceSpaceRevision: 1)
        var filter = PoseMotionFilter()
        XCTAssertNil(filter.accept(packet)); XCTAssertEqual(filter.lastRejection, .malformed)
    }
    func testInterruptionBreaksConsecutiveRecoveryAndGapDoesNotBypassSpeedLimit() {
        var filter = PoseMotionFilter()
        XCTAssertNotNil(filter.accept(pose(1, time: 1_000_000_000)))
        XCTAssertNil(filter.accept(pose(2, time: 2_000_000_000, x: 1000)))
        XCTAssertEqual(filter.lastRejection, .motion)
        XCTAssertNil(filter.accept(pose(3, time: 2_010_000_000, x: 10)))
        XCTAssertNil(filter.accept(pose(4, time: 2_020_000_000, x: 10.1)))
        filter.interruptReacquisition()
        XCTAssertNil(filter.accept(pose(5, time: 2_030_000_000, x: 10.2)))
        XCTAssertNil(filter.accept(pose(6, time: 2_040_000_000, x: 10.3)))
        XCTAssertNotNil(filter.accept(pose(7, time: 2_050_000_000, x: 10.4)))
    }
}
