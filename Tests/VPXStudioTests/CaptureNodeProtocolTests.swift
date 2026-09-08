import XCTest
import VPXCaptureProtocol

final class CaptureNodeProtocolTests: XCTestCase {
    func testHelloRoundTripsThroughJSON() throws {
        let hello = CaptureNodeHello(
            nodeID: UUID(),
            displayName: "iPhone A",
            capabilities: [.video, .pose, .imu, .timeSync]
        )

        let data = try JSONEncoder().encode(hello)
        XCTAssertEqual(try JSONDecoder().decode(CaptureNodeHello.self, from: data), hello)
    }

    func testPosePacketRoundTripsThroughJSON() throws {
        let pose = CapturePosePacket(
            sequence: 42,
            captureTimeNanoseconds: 123_456,
            translationMeters: [1, 2, 3],
            rotationQuaternion: [0, 0, 0, 1],
            linearVelocityMetersPerSecond: [0.1, 0, 0],
            angularVelocityRadiansPerSecond: [0, 0.2, 0],
            quality: .nominal,
            referenceSpaceRevision: 3
        )

        let data = try JSONEncoder().encode(pose)
        XCTAssertEqual(try JSONDecoder().decode(CapturePosePacket.self, from: data), pose)
    }

    func testLengthPrefixedHelloRoundTrips() throws {
        let hello = CaptureNodeHello(
            nodeID: UUID(),
            displayName: "iPhone B",
            capabilities: [.video, .pose]
        )
        let envelope = try CaptureMessageEnvelope(kind: .hello, payload: hello)

        let decoded = try CaptureMessageCodec.decodeFrame(
            CaptureMessageCodec.encode(envelope)
        )

        XCTAssertEqual(decoded.kind, .hello)
        XCTAssertEqual(try decoded.decodePayload(CaptureNodeHello.self), hello)
    }

    func testCodecRejectsIncompleteFrame() {
        XCTAssertThrowsError(try CaptureMessageCodec.decodeFrame(Data([0, 0, 0])))
    }

    func testStreamDecoderRestoresFragmentedAndCoalescedMessages() throws {
        let hello = CaptureNodeHello(
            nodeID: UUID(),
            displayName: "iPhone C",
            capabilities: [.video, .timeSync]
        )
        let helloFrame = try CaptureMessageCodec.encode(
            CaptureMessageEnvelope(kind: .hello, payload: hello)
        )
        let clock = CaptureClockSample(
            senderMonotonicNanoseconds: 400,
            echoedHostMonotonicNanoseconds: 300
        )
        let clockFrame = try CaptureMessageCodec.encode(
            CaptureMessageEnvelope(kind: .clockSample, payload: clock)
        )

        var decoder = CaptureMessageStreamDecoder()
        XCTAssertTrue(try decoder.append(helloFrame.prefix(2)).isEmpty)
        XCTAssertEqual(decoder.bufferedByteCount, 2)

        let firstBatch = try decoder.append(helloFrame.dropFirst(2))
        XCTAssertEqual(firstBatch.count, 1)
        XCTAssertEqual(try firstBatch[0].decodePayload(CaptureNodeHello.self), hello)

        let secondBatch = try decoder.append(helloFrame + clockFrame)
        XCTAssertEqual(secondBatch.map(\.kind), [.hello, .clockSample])
        XCTAssertEqual(
            try secondBatch[1].decodePayload(CaptureClockSample.self),
            clock
        )
    }

    func testClockEstimateCalculatesOffsetAndRoundTrip() throws {
        let estimate = try CaptureClockEstimate(
            exchange: CaptureClockExchange(
                hostSendNanoseconds: 1_000,
                nodeReceiveNanoseconds: 1_100,
                nodeSendNanoseconds: 1_120,
                hostReceiveNanoseconds: 1_060
            )
        )

        XCTAssertEqual(estimate.nodeClockOffsetNanoseconds, 80, accuracy: 0.001)
        XCTAssertEqual(estimate.roundTripNanoseconds, 40, accuracy: 0.001)
    }

    func testClockEstimateRejectsImpossibleExchange() {
        XCTAssertThrowsError(
            try CaptureClockEstimate(
                exchange: CaptureClockExchange(
                    hostSendNanoseconds: 1_000,
                    nodeReceiveNanoseconds: 1_100,
                    nodeSendNanoseconds: 1_090,
                    hostReceiveNanoseconds: 1_060
                )
            )
        )
    }

    func testControlCommandRoundTripsThroughFramedEnvelope() throws {
        let command = CaptureNodeControlCommand(
            action: .setVideoProfile,
            videoProfile: .uhd60HEVC
        )
        let encoded = try CaptureMessageCodec.encode(
            CaptureMessageEnvelope(kind: .control, payload: command)
        )

        let envelope = try CaptureMessageCodec.decodeFrame(encoded)
        XCTAssertEqual(envelope.kind, .control)
        XCTAssertEqual(
            try envelope.decodePayload(CaptureNodeControlCommand.self),
            command
        )
    }
}
