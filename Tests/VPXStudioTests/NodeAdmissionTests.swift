import XCTest
import VPXCaptureProtocol
@testable import VPXStudio

final class NodeAdmissionTests: XCTestCase {
    private func hello(_ node: UUID = UUID(), video: Bool = true) -> CaptureNodeHello {
        CaptureNodeHello(nodeID: node, displayName: "Node", capabilities: video ? [.video, .timeSync] : [.pose, .timeSync])
    }

    func testVideoBudgetPreservesTrackingSlotsAndRejectsWithoutConsumingCapacity() {
        var policy = NodeAdmissionPolicy(limits: .init(nodes: 3, videoStreams: 1))
        let video = UUID()
        XCTAssertEqual(policy.admit(hello(), connectionID: video), .accepted)
        XCTAssertEqual(policy.admit(hello(), connectionID: UUID()), .rejected(.videoLimit))
        XCTAssertEqual(policy.admit(hello(video: false), connectionID: UUID()), .accepted)
        XCTAssertEqual(policy.admit(hello(video: false), connectionID: UUID()), .accepted)
        XCTAssertEqual(policy.admit(hello(video: false), connectionID: UUID()), .rejected(.nodeLimit))
        policy.remove(connectionID: video)
        XCTAssertEqual(policy.admit(hello(), connectionID: UUID()), .accepted)
    }

    func testReconnectAtCapacityAndDelayedOldDisconnectDoNotReleaseNewReservation() {
        var policy = NodeAdmissionPolicy(limits: .init(nodes: 1, videoStreams: 1))
        let node = hello(), old = UUID(), replacement = UUID()
        XCTAssertEqual(policy.admit(node, connectionID: old), .accepted)
        XCTAssertEqual(policy.admit(node, connectionID: replacement), .accepted)
        policy.remove(connectionID: old)
        XCTAssertEqual(policy.admit(hello(), connectionID: UUID()), .rejected(.nodeLimit))
        policy.remove(connectionID: replacement)
        XCTAssertEqual(policy.admit(hello(), connectionID: UUID()), .accepted)
    }

    func testDuplicateHelloDoesNotResetSessionAndIdentityCannotChange() {
        var policy = NodeAdmissionPolicy()
        let node = hello(), connection = UUID()
        XCTAssertEqual(policy.admit(node, connectionID: connection), .accepted)
        XCTAssertEqual(policy.admit(node, connectionID: connection), .duplicate)
        XCTAssertEqual(policy.admit(hello(), connectionID: connection), .rejected(.identityChanged))
        XCTAssertEqual(policy.admit(hello(node.nodeID, video: false), connectionID: connection), .rejected(.capabilitiesChanged))
        XCTAssertEqual(policy.admit(node, connectionID: connection), .duplicate)
    }

    func testFailedUpgradePreservesExistingReservationAndResetReleasesAll() {
        var policy = NodeAdmissionPolicy(limits: .init(nodes: 2, videoStreams: 1))
        let tracker = hello(video: false), connection = UUID()
        XCTAssertEqual(policy.admit(tracker, connectionID: connection), .accepted)
        XCTAssertEqual(policy.admit(hello(), connectionID: UUID()), .accepted)
        XCTAssertEqual(policy.admit(hello(tracker.nodeID), connectionID: UUID()), .rejected(.videoLimit))
        XCTAssertEqual(policy.admit(tracker, connectionID: connection), .duplicate)
        policy.reset()
        XCTAssertEqual(policy.admit(hello(tracker.nodeID), connectionID: UUID()), .accepted)
    }
}
