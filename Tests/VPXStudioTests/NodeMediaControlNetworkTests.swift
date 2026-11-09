import XCTest
import Network
import VPXCaptureProtocol
@testable import VPXStudio

private final class MediaNetworkState: @unchecked Sendable {
    // All fields accessed on the same networking queue.
    var port: NWEndpoint.Port?
    weak var channel: CaptureSecureChannel?
}

final class NodeMediaControlNetworkTests: XCTestCase {
    @MainActor func testReliablePauseClockAndResumeRoundTrip() async throws {
        let queue = DispatchQueue(label: "vpx.test.media-control")
        let state = MediaNetworkState()
        let credential = try CapturePairingCredential.create()
        let ready = expectation(description: "Host ready")
        let paused = expectation(description: "Pause acknowledged")
        let clock = expectation(description: "Clock continues during pause")
        let resumed = expectation(description: "Resume acknowledged")
        let pause = CaptureNodeControlCommand(action: .suspendMedia)
        let resume = CaptureNodeControlCommand(action: .resumeMedia)
        let nodeID = UUID()
        let host = CaptureNodeBonjourHost(credential: credential, queue: queue)
        host.onReady = { port in state.port = port; ready.fulfill() }
        host.onHello = { _, channel in
            state.channel = channel
            channel.onClockReply = { [weak channel] reply in
                XCTAssertEqual(reply.hostSendNanoseconds, 100)
                clock.fulfill()
                do { try channel?.sendControl(CaptureMessageEnvelope(kind: .control, payload: resume)) }
                catch { XCTFail(error.localizedDescription) }
            }
            do { try channel.sendControl(CaptureMessageEnvelope(kind: .control, payload: pause)) }
            catch { XCTFail(error.localizedDescription) }
        }
        host.onMediaControlResult = { node, connection, result in
            XCTAssertEqual(node, nodeID); XCTAssertEqual(connection, state.channel?.connectionID)
            if result.commandID == pause.commandID {
                XCTAssertTrue(result.suspended); paused.fulfill()
                do { try state.channel?.sendClockProbe(.init(hostSendNanoseconds: 100)) }
                catch { XCTFail(error.localizedDescription) }
            } else {
                XCTAssertEqual(result.commandID, resume.commandID)
                XCTAssertFalse(result.suspended); resumed.fulfill()
            }
        }
        try host.start(port: .any)
        defer { host.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try queue.sync { try XCTUnwrap(state.port) }
        let client = CaptureSecureChannel(host: "127.0.0.1", port: port, credential: credential)
        defer { client.cancel() }
        let gate = CaptureMediaTransmissionGate()
        client.onStateChanged = { [weak client] status in
            if status == .ready {
                do { try client?.sendControl(CaptureMessageEnvelope(kind: .hello,
                    payload: CaptureNodeHello(nodeID: nodeID, displayName: "Test", capabilities: [.video, .timeSync]))) }
                catch { XCTFail(error.localizedDescription) }
            }
        }
        client.onControlPacket = { [weak client] envelope in
            guard envelope.kind == .control else { return }
            do {
                let command = try envelope.decodePayload(CaptureNodeControlCommand.self)
                try gate.apply(command) { result in
                    try client?.sendControl(CaptureMessageEnvelope(kind: .mediaControlResult, payload: result))
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        client.onClockProbe = { [weak client] probe in
            do { try client?.sendClockReply(.init(hostSendNanoseconds: probe.hostSendNanoseconds,
                nodeReceiveNanoseconds: 200, nodeSendNanoseconds: 201)) }
            catch { XCTFail(error.localizedDescription) }
        }
        client.start(on: queue)
        await fulfillment(of: [paused, clock, resumed], timeout: 5, enforceOrder: true)
    }
}
