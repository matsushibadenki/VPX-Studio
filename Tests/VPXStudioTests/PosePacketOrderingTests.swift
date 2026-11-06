import XCTest
import VPXCaptureProtocol

final class PosePacketOrderingTests: XCTestCase {
    private func pose(_ sequence: UInt64, _ timestamp: UInt64) -> CapturePosePacket {
        .init(sequence: sequence, captureTimeNanoseconds: timestamp,
              translationMeters: [0, 0, 0], rotationQuaternion: [0, 0, 0, 1],
              linearVelocityMetersPerSecond: [0, 0, 0], angularVelocityRadiansPerSecond: [0, 0, 0],
              quality: .nominal, referenceSpaceRevision: 1)
    }

    func testRejectsReplayAfterDeliveryAndReversedTimestamp() {
        var buffer = CapturePoseJitterBuffer(targetDelayNanoseconds: 0)
        buffer.enqueue(pose(2, 100), nodeClockOffsetNanoseconds: 0)
        XCTAssertEqual(buffer.dequeueLatestReady(hostNowNanoseconds: 100)?.sequence, 2)
        for packet in [pose(2, 100), pose(1, 99), pose(3, 99)] {
            buffer.enqueue(packet, nodeClockOffsetNanoseconds: 0)
        }
        XCTAssertNil(buffer.dequeueLatestReady(hostNowNanoseconds: 200))
        XCTAssertEqual(buffer.droppedPacketCount, 3)
        buffer.enqueue(pose(4, 201), nodeClockOffsetNanoseconds: 0)
        XCTAssertEqual(buffer.dequeueLatestReady(hostNowNanoseconds: 201)?.sequence, 4)
    }

    func testRejectsExpiredAndInvalidClockButAllowsFreshRecovery() {
        var buffer = CapturePoseJitterBuffer(targetDelayNanoseconds: 0, maximumAgeNanoseconds: 100)
        buffer.enqueue(pose(1, 100), nodeClockOffsetNanoseconds: 0)
        XCTAssertNil(buffer.dequeueLatestReady(hostNowNanoseconds: 201))
        buffer.enqueue(pose(2, 201), nodeClockOffsetNanoseconds: .nan)
        XCTAssertEqual(buffer.queuedPacketCount, 0)
        buffer.enqueue(pose(3, 202), nodeClockOffsetNanoseconds: 0)
        XCTAssertEqual(buffer.dequeueLatestReady(hostNowNanoseconds: 302)?.sequence, 3)
    }
}
