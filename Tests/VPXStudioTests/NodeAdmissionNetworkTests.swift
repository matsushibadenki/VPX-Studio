import XCTest
import Network
import VPXCaptureProtocol
@testable import VPXStudio

private final class AdmissionNetworkState: @unchecked Sendable {
    // Confined to the test networking queue.
    var port: NWEndpoint.Port?
    var accepted = 0
}

final class NodeAdmissionNetworkTests: XCTestCase {
    @MainActor func testAuthenticatedHostRejectsOverflowThenReleasesSlotOnDisconnect() async throws {
        let queue = DispatchQueue(label: "vpx.test.admission")
        let state = AdmissionNetworkState()
        let credential = try CapturePairingCredential.create()
        let host = CaptureNodeBonjourHost(credential: credential, queue: queue, limits: .init(nodes: 1, videoStreams: 1))
        let ready = expectation(description: "Host ready")
        let first = expectation(description: "First Node admitted")
        let rejected = expectation(description: "Second Node rejected before registration")
        let disconnected = expectation(description: "First Node released")
        let recovered = expectation(description: "New Node admitted after release")
        host.onReady = { port in state.port = port; ready.fulfill() }
        host.onHello = { _, _ in
            state.accepted += 1
            if state.accepted == 1 { first.fulfill() } else { recovered.fulfill() }
        }
        host.onAdmissionRejected = { _, reason in XCTAssertEqual(reason, .nodeLimit); rejected.fulfill() }
        host.onDisconnected = { _, _ in if state.accepted == 1 { disconnected.fulfill() } }
        try host.start(port: .any)
        defer { host.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try queue.sync { try XCTUnwrap(state.port) }
        func client() -> CaptureSecureChannel {
            let channel = CaptureSecureChannel(host: "127.0.0.1", port: port, credential: credential)
            let hello = CaptureNodeHello(nodeID: UUID(), displayName: "Test Node", capabilities: [.video, .timeSync])
            channel.onStateChanged = { [weak channel] status in
                if status == .ready {
                    do { try channel?.sendControl(CaptureMessageEnvelope(kind: .hello, payload: hello)) }
                    catch { XCTFail(error.localizedDescription) }
                }
            }
            channel.start(on: queue)
            return channel
        }
        let a = client()
        defer { a.cancel() }
        await fulfillment(of: [first], timeout: 5)
        let b = client()
        defer { b.cancel() }
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertEqual(queue.sync { state.accepted }, 1)
        a.cancel()
        await fulfillment(of: [disconnected], timeout: 5)
        let c = client()
        defer { c.cancel() }
        await fulfillment(of: [recovered], timeout: 5)
        XCTAssertEqual(queue.sync { state.accepted }, 2)
    }
}
