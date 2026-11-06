import Foundation
import XCTest
import VPXCaptureProtocol

final class PhaseTwoTests: XCTestCase {
    private func depth(sequence: UInt64 = 1, time: UInt64 = 1_000_000_000) throws -> CaptureDepthPacket {
        try CaptureDepthPacket(header: .init(sequence: sequence, captureTimeNanoseconds: time, width: 2, height: 1,
            depthEncoding: "depth-float32-le", confidenceEncoding: "confidence-uint8"),
            depth: Data([0, 0, 128, 63, 0, 0, 0, 64]), confidence: Data([2, 0]))
    }
    private func pose() -> CapturePosePacket {
        .init(sequence: 1, captureTimeNanoseconds: 1_000_000_000, translationMeters: [1, 2, 3],
              rotationQuaternion: [0, 0, 0, 1], linearVelocityMetersPerSecond: [0, 0, 0],
              angularVelocityRadiansPerSecond: [0.1, 0.2, 0.3], quality: .nominal,
              referenceSpaceRevision: 3, accelerationMetersPerSecondSquared: [0.3, 0.2, 0.1])
    }
    private func clock(rtt: Double = 2_000_000, jitter: Double = 100_000) -> CaptureClockStatistics {
        .init(nodeClockOffsetNanoseconds: 0, roundTripNanoseconds: rtt, jitterNanoseconds: jitter, acceptedSampleCount: 4)
    }
    func testDepthBinaryRoundTripAndMalformedLengths() throws {
        let packet=try depth()
        let encoded=try CaptureTransportPacketCodec.encode(.depth(packet))
        XCTAssertEqual(try CaptureTransportPacketCodec.decode(encoded), .depth(packet))
        XCTAssertThrowsError(try CaptureTransportPacketCodec.decode(encoded.dropLast()))
        XCTAssertThrowsError(try CaptureTransportPacketCodec.decode(encoded + Data([0])))
        XCTAssertThrowsError(try CaptureDepthPacket(header: packet.header, depth: Data(), confidence: packet.confidence))
        XCTAssertThrowsError(try CaptureDepthPacket(header: packet.header, depth: packet.depth, confidence: Data([3, 0])))
        let huge=CaptureDepthFrameHeader(sequence: 1, captureTimeNanoseconds: 1, width: .max, height: .max,
            depthEncoding: "depth-float32-le", confidenceEncoding: "confidence-uint8")
        XCTAssertThrowsError(try CaptureDepthPacket(header: huge, depth: Data(), confidence: Data()))
    }
    func testTelemetryFitsMTUAndRejectsTamperingAndWrongKey() throws {
        let credential=try CapturePairingCredential(sessionID: UUID(), secret: Data(repeating: 8, count: 32))
        let protector=CaptureControlMessageProtector(credential: credential)
        let envelope=CaptureDatagramEnvelope(nodeID: UUID(), connectionID: UUID(), sequence: 99, payload: .pose(pose()))
        let bytes=try envelope.seal(using: protector)
        XCTAssertLessThanOrEqual(bytes.count, 1200)
        XCTAssertEqual(try CaptureDatagramEnvelope.open(bytes, using: protector), envelope)
        var modified=bytes; modified[modified.count-1] ^= 1
        XCTAssertThrowsError(try CaptureDatagramEnvelope.open(modified, using: protector))
        let other=CaptureControlMessageProtector(credential: try .init(sessionID: UUID(), secret: Data(repeating: 9, count: 32)))
        XCTAssertThrowsError(try CaptureDatagramEnvelope.open(bytes, using: other))
        XCTAssertThrowsError(try CaptureDatagramEnvelope.open(Data(repeating: 0, count: 1201), using: protector))
    }
    func testReplayWindowAllowsReorderingAndRejectsDuplicatesAndExpiredPackets() {
        var replay=CaptureReplayWindow()
        XCTAssertTrue(replay.accept(200)); XCTAssertTrue(replay.accept(199))
        XCTAssertFalse(replay.accept(199)); XCTAssertFalse(replay.accept(72))
        XCTAssertTrue(replay.accept(201)); XCTAssertTrue(replay.accept(74))
        XCTAssertTrue(replay.accept(.max)); XCTAssertFalse(replay.accept(202))
    }
    func testClockMappingExactlyInvertsDriftAndRejectsInvalidModels() throws {
        // host=2s, reference=1s, offset=100ms, drift=1000ppm => node=2.101s.
        XCTAssertEqual(try XCTUnwrap(CaptureClockMapping.hostTime(nodeTime: 2_101_000_000,
            offset: 100_000_000, driftPPM: 1000, reference: 1_000_000_000)), 2_000_000_000, accuracy: 0.01)
        XCTAssertNil(CaptureClockMapping.hostTime(nodeTime: 1, offset: .nan, driftPPM: 0, reference: 0))
        XCTAssertNil(CaptureClockMapping.hostTime(nodeTime: 1, offset: 0, driftPPM: -1_000_000, reference: 0))
        XCTAssertTrue(CaptureSynchronizationPolicy().accepts(clock()))
        XCTAssertFalse(CaptureSynchronizationPolicy().accepts(clock(rtt: 200_000_000)))
        XCTAssertFalse(CaptureSynchronizationPolicy().accepts(clock(jitter: .nan)))
    }
    func testDepthRejectsExpiredUncertainAndReorderedData() throws {
        var buffer=CaptureDepthBuffer()
        XCTAssertTrue(buffer.receive(try depth(), clock: clock(), hostNow: 1_050_000_000))
        XCTAssertEqual(buffer.highConfidenceFraction, 0.5)
        XCTAssertFalse(buffer.receive(try depth(), clock: clock(), hostNow: 1_060_000_000))
        XCTAssertFalse(buffer.receive(try depth(sequence: 2), clock: clock(rtt: 200_000_000), hostNow: 1_060_000_000))
        XCTAssertFalse(buffer.receive(try depth(sequence: 2, time: 100), clock: clock(), hostNow: 1_060_000_000))
        XCTAssertNil(buffer.current(hostNow: 1_600_000_000))
        XCTAssertEqual(buffer.highConfidenceFraction, 0)
    }
    func testVideoExpiresAndCannotReplayAfterDelivery() {
        func frame(_ sequence: UInt64, _ time: UInt64) -> CaptureEncodedVideoFrame {
            .init(header: .init(sequence: sequence, captureTimeNanoseconds: time, width: 16, height: 16,
                codec: "hvc1", isKeyFrame: true), encodedData: Data([1]), parameterSets: [])
        }
        var buffer=CaptureVideoJitterBuffer(targetDelayNanoseconds: 0)
        buffer.enqueue(frame(1, 1_000_000_000), nodeClockOffsetNanoseconds: 0)
        XCTAssertEqual(buffer.dequeueReady(hostNowNanoseconds: 1_010_000_000).count, 1)
        buffer.enqueue(frame(1, 1_000_000_000), nodeClockOffsetNanoseconds: 0)
        buffer.enqueue(frame(2, 1_020_000_000), nodeClockOffsetNanoseconds: 0)
        XCTAssertTrue(buffer.dequeueReady(hostNowNanoseconds: 2_000_000_000).isEmpty)
        XCTAssertEqual(buffer.droppedFrameCount, 2)
    }
    func testMetadataAndQualityEventsSurviveWireTransport() throws {
        let metadata=CaptureCameraMetadata(cameraID: "back", source: "avcapture", colorPrimaries: "ITU_R_709_2",
            transferFunction: "ITU_R_709_2", yCbCrMatrix: "ITU_R_709_2", intrinsics: Array(repeating: 1, count: 9))
        let frame=CaptureEncodedVideoFrame(header: .init(sequence: 5, captureTimeNanoseconds: 1_000,
            width: 1920, height: 1080, codec: "hvc1", isKeyFrame: true, cameraMetadata: metadata), encodedData: Data([1]), parameterSets: [])
        XCTAssertEqual(try CaptureTransportPacketCodec.decode(CaptureTransportPacketCodec.encode(.video(frame))), .video(frame))
        for reason in [CaptureQualityEvent.Reason.relocalizing, .interrupted, .insufficientFeatures, .failed, .disconnected] {
            let event=CaptureQualityEvent(sequence: 1, captureTimeNanoseconds: 2, quality: .lost, reason: reason, referenceSpaceRevision: 3)
            let envelope=try CaptureMessageEnvelope(kind: .qualityEvent, payload: event)
            XCTAssertEqual(try envelope.decodePayload(CaptureQualityEvent.self), event)
        }
    }
}
