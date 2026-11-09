import XCTest
import VPXCaptureProtocol
@testable import VPXStudio

final class NodeMonitoringTests: XCTestCase {
    private func packet(_ sequence: UInt64, time: UInt64 = 10_000_000_000, battery: Double? = 0.7) -> CaptureNodeStatus {
        CaptureNodeStatus(sequence: sequence, captureTimeNanoseconds: time, batteryFraction: battery,
            batteryState: .charging, thermalState: .serious, isCapturing: true)
    }

    func testStatusExpiresByCaptureTimeAndCannotBeRefreshedByReplay() {
        var health = NodeStatusHealth()
        let original = packet(5)
        health.accept(original, capturedHost: 10_000_000_000, now: 10_100_000_000, clock: .current)
        XCTAssertEqual(health.current(now: 13_000_000_000, clock: .current), original)
        health.accept(packet(4), capturedHost: 13_000_000_000, now: 13_100_000_000, clock: .current)
        XCTAssertNil(health.current(now: 13_100_000_000, clock: .current))
        health.accept(packet(6, time: 10_000_000_001), capturedHost: 10_000_000_001, now: 14_000_000_000, clock: .current)
        XCTAssertEqual(health.packet, original)
        XCTAssertNil(health.current(now: 12_000_000_000, clock: .stale))
    }

    func testInvalidFutureAndUnsynchronizedStatusAreRejectedAndNodesAreIndependent() {
        var a = NodeStatusHealth(), b = NodeStatusHealth()
        for battery in [-0.1, 1.1, Double.nan, .infinity] {
            a.accept(packet(1, battery: battery), capturedHost: 10_000_000_000, now: 10_000_000_000, clock: .current)
        }
        a.accept(packet(1), capturedHost: 10_100_000_000, now: 10_000_000_000, clock: .current)
        a.accept(packet(1), capturedHost: 10_000_000_000, now: 10_000_000_000, clock: .unmeasured)
        XCTAssertNil(a.packet)
        b.accept(packet(9, battery: nil), capturedHost: 10_000_000_000, now: 10_000_000_000, clock: .current)
        XCTAssertNotNil(b.current(now: 10_000_000_001, clock: .current))
        // A reconnect creates a fresh status health, allowing a reset sequence.
        a.accept(packet(0), capturedHost: 10_000_000_000, now: 10_000_000_000, clock: .current)
        XCTAssertEqual(a.packet?.sequence, 0)
        XCTAssertEqual(b.packet?.sequence, 9)
    }

    func testStatusEncryptedDatagramFitsMTUAndDiagnosticsRoundTrips() throws {
        let status = packet(1)
        let payload = CaptureDatagramEnvelope(nodeID: UUID(), connectionID: UUID(), sequence: 1, payload: .nodeStatus(status))
        let protector = CaptureControlMessageProtector(credential: try .create())
        let encoded = try payload.seal(using: protector)
        XCTAssertLessThanOrEqual(encoded.count, CaptureDatagramEnvelope.maximumDatagramBytes)
        XCTAssertEqual(try CaptureDatagramEnvelope.open(encoded, using: protector), payload)
        let snapshot = NodeMonitoringSnapshot(id: payload.nodeID, name: "Camera A", connected: true, selected: false,
            clock: .current, frameAgeMilliseconds: 33, decodeMilliseconds: 2, poseQuality: .degraded,
            poseAgeMilliseconds: 10, roundTripMilliseconds: 5, jitterMilliseconds: 1, trackingReason: "initializing", status: status)
        let restored = try JSONDecoder().decode(NodeMonitoringSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.status, status)
        XCTAssertEqual(restored.id, payload.nodeID)
        XCTAssertEqual(restored.frameAgeMilliseconds, 33)
    }
}
