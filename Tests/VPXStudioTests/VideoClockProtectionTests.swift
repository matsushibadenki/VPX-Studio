import XCTest
import VPXCaptureProtocol
@testable import VPXStudio

final class VideoClockProtectionTests: XCTestCase {
    func testStoppedConnectionCannotResumeClockOrDecodeLateFrames() throws {
        let source = CaptureNodeHEVCVideoSource(hello: .init(nodeID: UUID(), displayName: "Old", capabilities: [.video]))
        let stats = CaptureClockStatistics(nodeClockOffsetNanoseconds: 0, roundTripNanoseconds: 20,
            jitterNanoseconds: 2, acceptedSampleCount: 1)
        source.updateClockModel(stats, acceptedAtNanoseconds: 100)
        source.stop()
        source.updateClockModel(stats, acceptedAtNanoseconds: 200)
        XCTAssertFalse(source.hasCurrentClock(at: 201))
        // Malformed late HEVC data must be discarded before VideoToolbox.
        let frame = CaptureEncodedVideoFrame(header: .init(sequence: 1, captureTimeNanoseconds: 200,
            width: 16, height: 16, codec: "hvc1", isKeyFrame: true), encodedData: Data([0]))
        XCTAssertNoThrow(try source.receive(frame))
        XCTAssertNil(source.monitoringSnapshot().captured)
        source.stop() // Teardown is idempotent.
    }
    func testClockExpiryRecoveryAndReconnectResetAreNodeLocal() {
        let a = CaptureNodeHEVCVideoSource(hello: .init(nodeID: UUID(), displayName: "A", capabilities: [.video]))
        let b = CaptureNodeHEVCVideoSource(hello: .init(nodeID: UUID(), displayName: "B", capabilities: [.video]))
        let stats = CaptureClockStatistics(nodeClockOffsetNanoseconds: 100, roundTripNanoseconds: 20,
                                           jitterNanoseconds: 2, acceptedSampleCount: 1)
        var requests = 0
        a.onKeyFrameNeeded = { requests += 1 }
        XCTAssertFalse(a.hasCurrentClock(at: 100))
        a.updateClockModel(stats, acceptedAtNanoseconds: 100)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(a.hasCurrentClock(at: 3_000_000_100))
        XCTAssertFalse(a.hasCurrentClock(at: 3_000_000_101))
        XCTAssertFalse(b.hasCurrentClock(at: 100))
        a.updateClockModel(stats, acceptedAtNanoseconds: 4_000_000_000)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(a.hasCurrentClock(at: 4_000_000_001))
        a.resetClockModel()
        XCTAssertFalse(a.hasCurrentClock(at: 4_000_000_001))
        a.updateClockModel(stats, acceptedAtNanoseconds: 4_000_000_002)
        XCTAssertEqual(requests, 3)
        a.updateClockModel(stats, acceptedAtNanoseconds: 4_000_000_003)
        XCTAssertEqual(requests, 3) // Healthy periodic sync does not spam controls.
    }
}
