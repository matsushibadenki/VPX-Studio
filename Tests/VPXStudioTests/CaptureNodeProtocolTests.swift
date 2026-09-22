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

    func testEncodedFramePreservesKeyFrameDecoderConfiguration() {
        let header = CaptureVideoFrameHeader(
            sequence: 9,
            captureTimeNanoseconds: 500,
            width: 1_920,
            height: 1_080,
            codec: "hvc1",
            isKeyFrame: true
        )
        let frame = CaptureEncodedVideoFrame(
            header: header,
            encodedData: Data([0, 0, 0, 4, 0x26, 1, 2, 3]),
            parameterSets: [Data([1]), Data([2]), Data([3])]
        )

        XCTAssertEqual(frame.header, header)
        XCTAssertEqual(frame.parameterSets.count, 3)
        XCTAssertFalse(frame.encodedData.isEmpty)
    }

    func testPairingCredentialProtectsControlEnvelope() throws {
        let credential = try CapturePairingCredential(
            sessionID: UUID(),
            secret: Data(repeating: 7, count: 32)
        )
        let protector = CaptureControlMessageProtector(credential: credential)
        let command = CaptureNodeControlCommand(action: .requestKeyFrame)
        let envelope = try CaptureMessageEnvelope(kind: .control, payload: command)

        let encrypted = try protector.seal(envelope)
        XCTAssertNotEqual(encrypted.combinedSealedBox, envelope.payload)
        XCTAssertEqual(try protector.open(encrypted), envelope)
    }

    func testPairingCredentialRejectsDifferentSession() throws {
        let secret = Data(repeating: 4, count: 32)
        let sender = CaptureControlMessageProtector(
            credential: try CapturePairingCredential(sessionID: UUID(), secret: secret)
        )
        let receiver = CaptureControlMessageProtector(
            credential: try CapturePairingCredential(sessionID: UUID(), secret: secret)
        )
        let envelope = try CaptureMessageEnvelope(
            kind: .control,
            payload: CaptureNodeControlCommand(action: .beginClockSync)
        )

        XCTAssertThrowsError(try receiver.open(sender.seal(envelope))) { error in
            XCTAssertEqual(error as? CapturePairingError, .sessionMismatch)
        }
    }

    func testPairingCredentialRoundTripsThroughQRPayload() throws {
        let credential = try CapturePairingCredential(
            sessionID: UUID(),
            secret: Data(repeating: 0x42, count: 32)
        )

        let decoded = try CapturePairingCredential(qrPayload: credential.qrPayload)
        XCTAssertEqual(decoded, credential)
        XCTAssertEqual(decoded.verificationCode, credential.verificationCode)
    }

    func testPoseTransportPacketRoundTrips() throws {
        let pose = CapturePosePacket(
            sequence: 88,
            captureTimeNanoseconds: 1_234,
            translationMeters: [1, 2, 3],
            rotationQuaternion: [0, 0, 0, 1],
            linearVelocityMetersPerSecond: [0, 0, 0],
            angularVelocityRadiansPerSecond: [0.1, 0.2, 0.3],
            quality: .nominal,
            referenceSpaceRevision: 5
        )

        XCTAssertEqual(
            try CaptureTransportPacketCodec.decode(
                CaptureTransportPacketCodec.encode(.pose(pose))
            ),
            .pose(pose)
        )
    }

    func testClockTransportPacketsRoundTrip() throws {
        let probe = CaptureClockProbe(hostSendNanoseconds: 1_000)
        let reply = CaptureClockReply(
            hostSendNanoseconds: 1_000,
            nodeReceiveNanoseconds: 1_030,
            nodeSendNanoseconds: 1_035
        )

        XCTAssertEqual(
            try CaptureTransportPacketCodec.decode(CaptureTransportPacketCodec.encode(.clockProbe(probe))),
            .clockProbe(probe)
        )
        XCTAssertEqual(
            try CaptureTransportPacketCodec.decode(CaptureTransportPacketCodec.encode(.clockReply(reply))),
            .clockReply(reply)
        )
    }

    func testClockSynchronizerRejectsExtremeRTTOutlier() throws {
        var synchronizer = CaptureClockSynchronizer(maximumSamples: 8)
        for index in 0..<3 {
            let base = UInt64(index * 100_000)
            _ = try synchronizer.record(
                CaptureClockExchange(
                    hostSendNanoseconds: base,
                    nodeReceiveNanoseconds: base + 1_010,
                    nodeSendNanoseconds: base + 1_020,
                    hostReceiveNanoseconds: base + 2_030
                )
            )
        }
        let outlier = try synchronizer.record(
            CaptureClockExchange(
                hostSendNanoseconds: 1_000_000,
                nodeReceiveNanoseconds: 1_001_010,
                nodeSendNanoseconds: 1_001_020,
                hostReceiveNanoseconds: 9_000_000
            )
        )

        XCTAssertFalse(outlier.wasAccepted)
        XCTAssertEqual(outlier.statistics.acceptedSampleCount, 3)
    }

    func testVideoJitterBufferOrdersFramesInHostClockDomain() {
        func frame(sequence: UInt64, timestamp: UInt64) -> CaptureEncodedVideoFrame {
            CaptureEncodedVideoFrame(
                header: CaptureVideoFrameHeader(
                    sequence: sequence,
                    captureTimeNanoseconds: timestamp,
                    width: 16,
                    height: 16,
                    codec: "hvc1",
                    isKeyFrame: sequence == 1
                ),
                encodedData: Data([UInt8(sequence)])
            )
        }

        var buffer = CaptureVideoJitterBuffer(targetDelayNanoseconds: 10, maximumFrameCount: 3)
        buffer.enqueue(frame(sequence: 2, timestamp: 120), nodeClockOffsetNanoseconds: 20)
        buffer.enqueue(frame(sequence: 1, timestamp: 110), nodeClockOffsetNanoseconds: 20)

        XCTAssertEqual(buffer.dequeueReady(hostNowNanoseconds: 100).map(\.header.sequence), [1])
        XCTAssertEqual(buffer.dequeueReady(hostNowNanoseconds: 120).map(\.header.sequence), [2])
    }

    func testPoseJitterBufferUsesLatestReadyPose() {
        func pose(sequence: UInt64, timestamp: UInt64) -> CapturePosePacket {
            CapturePosePacket(
                sequence: sequence,
                captureTimeNanoseconds: timestamp,
                translationMeters: [Float(sequence), 0, 0],
                rotationQuaternion: [0, 0, 0, 1],
                linearVelocityMetersPerSecond: [0, 0, 0],
                angularVelocityRadiansPerSecond: [0, 0, 0],
                quality: .nominal,
                referenceSpaceRevision: 1
            )
        }
        var buffer = CapturePoseJitterBuffer(targetDelayNanoseconds: 10)
        buffer.enqueue(pose(sequence: 1, timestamp: 110), nodeClockOffsetNanoseconds: 20)
        buffer.enqueue(pose(sequence: 2, timestamp: 115), nodeClockOffsetNanoseconds: 20)

        XCTAssertEqual(buffer.dequeueLatestReady(hostNowNanoseconds: 110)?.sequence, 2)
    }

    func testClockSynchronizerEstimatesDrift() throws {
        var synchronizer = CaptureClockSynchronizer(maximumSamples: 8)
        _ = try synchronizer.record(
            CaptureClockExchange(
                hostSendNanoseconds: 0,
                nodeReceiveNanoseconds: 1_000,
                nodeSendNanoseconds: 1_000,
                hostReceiveNanoseconds: 2_000
            )
        )
        let result = try synchronizer.record(
            CaptureClockExchange(
                hostSendNanoseconds: 1_000_000,
                nodeReceiveNanoseconds: 1_002_000,
                nodeSendNanoseconds: 1_002_000,
                hostReceiveNanoseconds: 1_002_000
            )
        )

        XCTAssertEqual(result.statistics.driftPartsPerMillion, 1_000, accuracy: 0.1)
    }

    func testEncryptedVideoTransportRoundTripsAcrossFragments() throws {
        let credential = try CapturePairingCredential(
            sessionID: UUID(),
            secret: Data(repeating: 9, count: 32)
        )
        let protector = CaptureControlMessageProtector(credential: credential)
        let frame = CaptureEncodedVideoFrame(
            header: CaptureVideoFrameHeader(
                sequence: 20,
                captureTimeNanoseconds: 900,
                width: 1_920,
                height: 1_080,
                codec: "hvc1",
                isKeyFrame: true
            ),
            encodedData: Data(repeating: 0xAB, count: 1_024),
            parameterSets: [Data([1, 2]), Data([3, 4]), Data([5, 6])]
        )
        let clearPacket = try CaptureTransportPacketCodec.encode(.video(frame))
        let encryptedPacket = try protector.sealPayload(clearPacket)
        let streamFrame = try CaptureTransportStreamCodec.encode(encryptedPacket)

        var streamDecoder = CaptureTransportStreamDecoder()
        XCTAssertTrue(try streamDecoder.append(streamFrame.prefix(7)).isEmpty)
        let packets = try streamDecoder.append(streamFrame.dropFirst(7))
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(
            try CaptureTransportPacketCodec.decode(try protector.openPayload(packets[0])),
            .video(frame)
        )
    }

    func testEncryptedTransportRejectsModifiedCiphertext() throws {
        let protector = CaptureControlMessageProtector(
            credential: try CapturePairingCredential(sessionID: UUID(), secret: Data(repeating: 1, count: 32))
        )
        var encrypted = try protector.sealPayload(Data([1, 2, 3]))
        encrypted[encrypted.startIndex] ^= 0xFF

        XCTAssertThrowsError(try protector.openPayload(encrypted)) { error in
            XCTAssertEqual(error as? CapturePairingError, .decryptionFailed)
        }
    }
}
