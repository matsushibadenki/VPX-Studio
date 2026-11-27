import CoreMedia
import CoreVideo
import Foundation
import VPXCaptureProtocol

/// Host-side adapter for an authenticated, ordered HEVC stream from one iPhone
/// Capture Node. Networking hands frames to `receive(_:)`; decoding and the
/// existing Metal ingestion path remain independent from the transport choice.
final class CaptureNodeHEVCVideoSource: VideoSource {
    private(set) var descriptor: DeviceDescriptor
    var onFrame: ((VideoFrame) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onKeyFrameNeeded: (() -> Void)?

    private let decoder = MacHEVCVideoDecoder()
    // Decode submission and teardown cannot run concurrently. Decoder callbacks
    // only take bufferLock, never decoderLock.
    private let decoderLock = NSLock()
    private let bufferLock = NSLock()
    private var jitterBuffer = CaptureVideoJitterBuffer()
    private var nodeClockOffsetNanoseconds = 0.0
    private var clockDriftPartsPerMillion = 0.0
    private var clockReferenceHostNanoseconds = 0.0
    private var clockLastAcceptedNanoseconds: UInt64?
    private var receivedTimes: [UInt64: Double] = [:]
    private var awaitingKeyFrame = true
    private var monitoring = NodeVideoMonitoring()
    private var stopped = false
    private var mediaSuspended = false
    private var mediaGeneration = UUID()

    func setMediaSuspended(_ suspended: Bool) {
        bufferLock.withLock {
            mediaSuspended = suspended; mediaGeneration = UUID()
            jitterBuffer = CaptureVideoJitterBuffer(); receivedTimes.removeAll()
            awaitingKeyFrame = true; monitoring = NodeVideoMonitoring()
        }
    }

    func monitoringSnapshot() -> NodeVideoMonitoring { bufferLock.withLock { monitoring } }

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

    func updateHello(_ hello: CaptureNodeHello) {
        descriptor=DeviceDescriptor(id: hello.nodeID, displayName: hello.displayName,
            capabilities: Self.deviceCapabilities(from: hello.capabilities))
    }

    func stop() {
        bufferLock.withLock { stopped = true }
        resetClockModel()
        decoderLock.withLock {
            decoder.completeFrames()
            decoder.invalidate()
        }
    }

    func receive(_ encodedFrame: CaptureEncodedVideoFrame) throws {
        var requestKeyFrame=false
        let readyFrames = bufferLock.withLock { () -> [(CaptureEncodedVideoFrame, FrameTelemetry)] in
            guard !stopped, !mediaSuspended else { return [] }
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
            let drops=jitterBuffer.droppedFrameCount
            jitterBuffer.enqueue(
                encodedFrame,
                nodeClockOffsetNanoseconds: nodeClockOffsetNanoseconds,
                clockDriftPartsPerMillion: clockDriftPartsPerMillion,
                referenceHostNanoseconds: clockReferenceHostNanoseconds
            )
            let ready=jitterBuffer.dequeueReady(
                hostNowNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            if jitterBuffer.droppedFrameCount != drops {
                awaitingKeyFrame=true; requestKeyFrame=true
                let queued=Set(ready.map(\.header.sequence))
                receivedTimes=receivedTimes.filter { queued.contains($0.key) }
            }
            return ready.filter { frame in
                if frame.header.isKeyFrame { awaitingKeyFrame=false }
                return !awaitingKeyFrame
            }.map { frame in
                let capture = HostClockMapping.hostTime(nodeNanoseconds: frame.header.captureTimeNanoseconds,
                    offset: nodeClockOffsetNanoseconds, driftPPM: clockDriftPartsPerMillion,
                    referenceHost: clockReferenceHostNanoseconds)
                return (frame, FrameTelemetry(sourceGeneration: mediaGeneration, captured: capture.map { $0 / 1_000_000_000 },
                    received: receivedTimes.removeValue(forKey: frame.header.sequence),
                    encodeCompleted: frame.header.encodeCompletedNanoseconds.flatMap {
                        HostClockMapping.hostTime(nodeNanoseconds: $0, offset: nodeClockOffsetNanoseconds,
                            driftPPM: clockDriftPartsPerMillion, referenceHost: clockReferenceHostNanoseconds)
                    }.map { $0 / 1_000_000_000 }))
            }
        }
        if requestKeyFrame { onKeyFrameNeeded?() }
        for (frame, telemetry) in readyFrames {
            try decoderLock.withLock {
                guard bufferLock.withLock({ !stopped }) else { return }
                try decoder.decode(frame, telemetry: telemetry)
            }
        }
    }

    func updateClockModel(_ statistics: CaptureClockStatistics,
                          acceptedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard CaptureSynchronizationPolicy().accepts(statistics) else { resetClockModel(); return }
        let needsKeyFrame = bufferLock.withLock {
            guard !stopped else { return false }
            let needsKeyFrame = ClockFreshness.evaluate(lastAccepted: clockLastAcceptedNanoseconds,
                now: acceptedAtNanoseconds) != .current
            if needsKeyFrame {
                jitterBuffer = CaptureVideoJitterBuffer()
                receivedTimes.removeAll()
                awaitingKeyFrame = true
                monitoring = NodeVideoMonitoring()
            }
            clockLastAcceptedNanoseconds = acceptedAtNanoseconds
            nodeClockOffsetNanoseconds = statistics.nodeClockOffsetNanoseconds
            clockDriftPartsPerMillion = statistics.driftPartsPerMillion
            clockReferenceHostNanoseconds = statistics.referenceHostNanoseconds
            return needsKeyFrame
        }
        if needsKeyFrame { onKeyFrameNeeded?() }
    }

    func hasCurrentClock(at now: UInt64) -> Bool {
        bufferLock.withLock {
            !stopped && ClockFreshness.evaluate(lastAccepted: clockLastAcceptedNanoseconds, now: now) == .current
        }
    }

    func resetClockModel() {
        bufferLock.withLock {
            clockLastAcceptedNanoseconds = nil
            jitterBuffer = CaptureVideoJitterBuffer()
            receivedTimes.removeAll()
            awaitingKeyFrame=true
            monitoring = NodeVideoMonitoring()
        }
    }

    private func publish(header: CaptureVideoFrameHeader, pixelBuffer: CVPixelBuffer, telemetry: FrameTelemetry) {
        guard hasCurrentClock(at: DispatchTime.now().uptimeNanoseconds) else { return }
        let now=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        guard let captured=telemetry.captured, now-captured >= -0.05, now-captured <= 0.5 else { return }
        let captureTime = CMTime(
            value: Int64(clamping: header.captureTimeNanoseconds),
            timescale: 1_000_000_000
        )
        let hostReceiveTime = CMClockGetTime(CMClockGetHostTimeClock())
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard !stopped, !mediaSuspended, telemetry.sourceGeneration == mediaGeneration else { return }
        monitoring = NodeVideoMonitoring(captured: captured, decoded: telemetry.decodeCompleted,
            decodeMilliseconds: FrameTelemetry.milliseconds(from: telemetry.decodeStarted, to: telemetry.decodeCompleted),
            lensFrame: header.cameraMetadata.map {
                NodeLensFrame(sequence: header.sequence, captureNodeNanoseconds: header.captureTimeNanoseconds,
                    captureHostSeconds: captured, metadata: $0)
            })
        onFrame?(
            VideoFrame(
                identifier: header.sequence,
                captureTime: captureTime,
                hostReceiveTime: hostReceiveTime,
                colorMetadata: header.cameraMetadata.map {
                    VideoColorMetadata(colorPrimaries: $0.colorPrimaries, transferFunction: $0.transferFunction, yCbCrMatrix: $0.yCbCrMatrix)
                } ?? VideoColorMetadata.read(from: pixelBuffer),
                pixelBuffer: pixelBuffer,
                quality: .nominal,
                telemetry: telemetry, capturedLens: header.cameraMetadata?.lens,
                arKitCaptureNanoseconds: header.cameraMetadata?.source == "arkit" ? header.captureTimeNanoseconds : nil
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
