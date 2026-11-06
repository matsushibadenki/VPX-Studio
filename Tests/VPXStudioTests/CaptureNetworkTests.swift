import XCTest
import Network
import VPXCaptureProtocol

private final class CaptureNetworkTestState: @unchecked Sendable {
    // These references are accessed exclusively on the test's serial queue.
    var clients: [CaptureDatagramChannel] = []
    var stream: CaptureSecureChannel?
}

final class CaptureNetworkTests: XCTestCase {
    @MainActor func testUDPLoopbackAcceptsOnlyNegotiatedSession() async throws {
        let received=expectation(description: "Authenticated UDP pose arrives")
        received.assertForOverFulfill=true
        let queue=DispatchQueue(label: "vpx.test.udp")
        let state=CaptureNetworkTestState()
        let credential=try CapturePairingCredential(sessionID: UUID(), secret: Data(repeating: 7, count: 32))
        let nodeID=UUID(), token=UUID()
        let pose=CapturePosePacket(sequence: 1, captureTimeNanoseconds: 1, translationMeters: [0, 0, 0],
            rotationQuaternion: [0, 0, 0, 1], linearVelocityMetersPerSecond: [0, 0, 0],
            angularVelocityRadiansPerSecond: [0, 0, 0], quality: .nominal, referenceSpaceRevision: 1)
        let listener=CaptureDatagramListener(credential: credential, queue: queue)
        listener.bind(nodeID: nodeID, connectionID: token)
        listener.onPayload = { node, payload in
            XCTAssertEqual(node, nodeID); XCTAssertEqual(payload, .pose(pose)); received.fulfill()
        }
        listener.onFailure = { error in XCTFail(error.localizedDescription) }
        listener.onReady = { port in
            let wrong=CaptureDatagramChannel(host: "127.0.0.1", port: port, credential: credential,
                nodeID: nodeID, connectionID: UUID(), queue: queue)
            let right=CaptureDatagramChannel(host: "127.0.0.1", port: port, credential: credential,
                nodeID: nodeID, connectionID: token, queue: queue)
            state.clients=[wrong, right]
            wrong.start(); right.start()
            wrong.send(.pose(pose)); right.send(.pose(pose))
        }
        try listener.start()
        await fulfillment(of: [received], timeout: 5)
        queue.sync { state.clients.forEach { $0.cancel() }; state.clients.removeAll() }
        listener.stop()
    }

    @MainActor func testReliableClockExchangeAndRemoteClose() async throws {
        let exchanged=expectation(description: "Clock reply over encrypted stream")
        let closed=expectation(description: "Remote EOF cancels accepted channel")
        let queue=DispatchQueue(label: "vpx.test.tcp")
        let state=CaptureNetworkTestState()
        let credential=try CapturePairingCredential(sessionID: UUID(), secret: Data(repeating: 3, count: 32))
        let listener=try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            let stream=CaptureSecureChannel(connection: connection, credential: credential)
            state.stream=stream
            stream.onClockProbe = { [weak stream] probe in
                try? stream?.sendClockReply(.init(hostSendNanoseconds: probe.hostSendNanoseconds,
                    nodeReceiveNanoseconds: 200, nodeSendNanoseconds: 300))
            }
            stream.onStateChanged = { status in if status == .cancelled { closed.fulfill() } }
            stream.start(on: queue)
        }
        let started=expectation(description: "Listener started")
        listener.stateUpdateHandler = { status in if case .ready = status { started.fulfill() } }
        listener.start(queue: queue)
        await fulfillment(of: [started], timeout: 5)
        let client=CaptureSecureChannel(host: "127.0.0.1", port: try XCTUnwrap(listener.port), credential: credential)
        client.onStateChanged = { [weak client] status in
            if status == .ready { try? client?.sendClockProbe(.init(hostSendNanoseconds: 100)) }
        }
        client.onClockReply = { reply in
            XCTAssertEqual(reply.hostSendNanoseconds, 100)
            XCTAssertEqual(reply.nodeReceiveNanoseconds, 200)
            exchanged.fulfill()
        }
        client.start(on: queue)
        await fulfillment(of: [exchanged], timeout: 5)
        client.cancel()
        await fulfillment(of: [closed], timeout: 5)
        listener.cancel()
        queue.sync { state.stream?.cancel(); state.stream=nil }
    }
}
