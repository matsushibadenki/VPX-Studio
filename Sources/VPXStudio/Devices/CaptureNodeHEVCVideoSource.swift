import CoreMedia
import CoreVideo
import Foundation
import VPXCaptureProtocol

/// Host-side adapter for an authenticated, ordered HEVC stream from one iPhone
/// Capture Node. Networking hands frames to `receive(_:)`; decoding and the
/// existing Metal ingestion path remain independent from the transport choice.
final class CaptureNodeHEVCVideoSource: VideoSource {
    let descriptor: DeviceDescriptor
    var onFrame: ((VideoFrame) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let decoder = MacHEVCVideoDecoder()
    private let bufferLock = NSLock()
    private var jitterBuffer = CaptureVideoJitterBuffer()
    private var nodeClockOffsetNanoseconds = 0.0
    private var clockDriftPartsPerMillion = 0.0
    private var clockReferenceHostNanoseconds = 0.0
    private var clockLastAcceptedNanoseconds: UInt64?
    private var receivedTimes: [UInt64: Double] = [:]

    init(hello: CaptureNodeHello) {
        descriptor = DeviceDescriptor(
            id: hello.nodeID,
            displayName: hello.displayName,
            capabilities: Self.deviceCapabilities(from: hello.capabilities)
        )
        decoder.onDecodedFrame = { [weak self] header, pixelBuffer, telemetry in
            self?.publish(header: header, pixelBuffer: pixelBuffer, telemetry: telemetry)
        }
        decoder.onError = { [weak self] error in
            self?.onFailure?(error)
        }
    }

    func start() throws {}

    func stop() {
        resetClockModel()
        decoder.completeFrames()
        decoder.invalidate()
    }

    func receive(_ encodedFrame: CaptureEncodedVideoFrame) throws {
        let readyFrames = bufferLock.withLock { () -> [(CaptureEncodedVideoFrame, FrameTelemetry)] in
            let received = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            receivedTimes[encodedFrame.header.sequence] = received
            if receivedTimes.count > 64, let oldest = receivedTimes.keys.min() { receivedTimes.removeValue(forKey: oldest) }
            guard ClockFreshness.evaluate(lastAccepted: clockLastAcceptedNanoseconds,
                                          now: DispatchTime.now().uptimeNanoseconds) == .current else {
                jitterBuffer = CaptureVideoJitterBuffer()
                // Keep HEVC reference frames up to date while suppressing output.
                receivedTimes.removeAll()
                return [(encodedFrame, FrameTelemetry(received: received))]
            }
            jitterBuffer.enqueue(
                encodedFrame,
                nodeClockOffsetNanoseconds: nodeClockOffsetNanoseconds,
                clockDriftPartsPerMillion: clockDriftPartsPerMillion,
                referenceHostNanoseconds: clockReferenceHostNanoseconds
            )
            return jitterBuffer.dequeueReady(
                hostNowNanoseconds: DispatchTime.now().uptimeNanoseconds
            ).map { frame in
                let capture = HostClockMapping.hostTime(nodeNanoseconds: frame.header.captureTimeNanoseconds,
                    offset: nodeClockOffsetNanoseconds, driftPPM: clockDriftPartsPerMillion,
                    referenceHost: clockReferenceHostNanoseconds)
                return (frame, FrameTelemetry(captured: capture.map { $0 / 1_000_000_000 },
                    received: receivedTimes.removeValue(forKey: frame.header.sequence),
                    encodeCompleted: frame.header.encodeCompletedNanoseconds.flatMap {
                        HostClockMapping.hostTime(nodeNanoseconds: $0, offset: nodeClockOffsetNanoseconds,
                            driftPPM: clockDriftPartsPerMillion, referenceHost: clockReferenceHostNanoseconds)
                    }.map { $0 / 1_000_000_000 }))
            }
        }
        for (frame, telemetry) in readyFrames {
            try decoder.decode(frame, telemetry: telemetry)
        }
    }

    func updateClockModel(_ statistics: CaptureClockStatistics,
                          acceptedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        bufferLock.withLock {
            clockLastAcceptedNanoseconds = acceptedAtNanoseconds
            nodeClockOffsetNanoseconds = statistics.nodeClockOffsetNanoseconds
            clockDriftPartsPerMillion = statistics.driftPartsPerMillion
            clockReferenceHostNanoseconds = statistics.referenceHostNanoseconds
        }
    }

    func hasCurrentClock(at now: UInt64) -> Bool {
        bufferLock.withLock {
            ClockFreshness.evaluate(lastAccepted: clockLastAcceptedNanoseconds, now: now) == .current
        }
    }

    func resetClockModel() {
        bufferLock.withLock {
            clockLastAcceptedNanoseconds = nil
            jitterBuffer = CaptureVideoJitterBuffer()
            receivedTimes.removeAll()
        }
    }

    private func publish(header: CaptureVideoFrameHeader, pixelBuffer: CVPixelBuffer, telemetry: FrameTelemetry) {
        guard hasCurrentClock(at: DispatchTime.now().uptimeNanoseconds) else { return }
        let captureTime = CMTime(
            value: Int64(clamping: header.captureTimeNanoseconds),
            timescale: 1_000_000_000
        )
        let hostReceiveTime = CMClockGetTime(CMClockGetHostTimeClock())
        onFrame?(
            VideoFrame(
                identifier: header.sequence,
                captureTime: captureTime,
                hostReceiveTime: hostReceiveTime,
                colorMetadata: VideoColorMetadata(
                    colorPrimaries: nil,
                    transferFunction: nil,
                    yCbCrMatrix: nil
                ),
                pixelBuffer: pixelBuffer,
                quality: .nominal,
                telemetry: telemetry
            )
        )
    }

    private static func deviceCapabilities(
        from captureCapabilities: Set<CaptureNodeCapability>
    ) -> Set<DeviceCapability> {
        var capabilities: Set<DeviceCapability> = []
        if captureCapabilities.contains(.video) { capabilities.insert(.video) }
        if captureCapabilities.contains(.pose) { capabilities.insert(.pose) }
        if captureCapabilities.contains(.depth) { capabilities.insert(.depth) }
        if captureCapabilities.contains(.lensMetadata) { capabilities.insert(.lens) }
        return capabilities
    }
}
