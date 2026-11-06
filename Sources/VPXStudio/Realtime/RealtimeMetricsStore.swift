import CoreMedia
import Foundation
import QuartzCore
import IOSurface

struct RealtimeMetricsSnapshot: Codable, Sendable {
    var pipeline = PipelineMeasurements()
    var inputHealth: VideoInputHealth = .missing
    var frameRate: Double = 0
    var gpuFrameMilliseconds: Double = 0
    var inputAgeMilliseconds: Double = 0
    var droppedFrameEstimate: UInt64 = 0
    var renderedFrameCount: UInt64 = 0
}

/// The renderer and capture queues publish metrics here without blocking each
/// other. UI reads an immutable snapshot at a lower cadence than rendering.
final class RealtimeMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = RealtimeMetricsSnapshot()
    private var frameWindowStart = CACurrentMediaTime()
    private var framesInWindow: UInt64 = 0
    private var previousFrameStart: CFTimeInterval?
    private var lastFrameIdentifier: UInt64?
    private var lastReceiveTime: Double?
    private var seenBuffers: [UInt] = []
    private var seenSurfaces: [UInt32] = []

    func recordInput(_ frame: VideoFrame, renderTime: Double, importMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        snapshot.pipeline.textureImportMilliseconds = importMilliseconds
        let timing = frame.telemetry
        snapshot.pipeline.captureToEncodeMilliseconds = FrameTelemetry.milliseconds(from: timing.captured, to: timing.encodeCompleted)
        snapshot.pipeline.transportMilliseconds = FrameTelemetry.milliseconds(from: timing.encodeCompleted, to: timing.received)
        snapshot.pipeline.captureToReceiveMilliseconds = FrameTelemetry.milliseconds(from: timing.captured, to: timing.received)
        snapshot.pipeline.receiveToDecodeMilliseconds = FrameTelemetry.milliseconds(from: timing.received, to: timing.decodeStarted)
        snapshot.pipeline.decodeMilliseconds = FrameTelemetry.milliseconds(from: timing.decodeStarted, to: timing.decodeCompleted)
        snapshot.pipeline.decodeToRenderMilliseconds = FrameTelemetry.milliseconds(from: timing.decodeCompleted ?? timing.received, to: renderTime)
        if lastFrameIdentifier == frame.identifier, lastReceiveTime == timing.received { return }
        lastFrameIdentifier = frame.identifier
        lastReceiveTime = timing.received
        snapshot.pipeline.observedFrames &+= 1
        snapshot.pipeline.knownCPUCopyCount &+= timing.knownCPUCopyCount
        snapshot.pipeline.knownCPUCopyBytes &+= timing.knownCPUCopyBytes
        let identity = UInt(bitPattern: Unmanaged.passUnretained(frame.pixelBuffer).toOpaque())
        if seenBuffers.contains(identity) { snapshot.pipeline.pixelBufferReuseCount &+= 1 }
        seenBuffers.append(identity)
        if seenBuffers.count > 256 { seenBuffers.removeFirst() }
        if let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() {
            let id = IOSurfaceGetID(surface)
            snapshot.pipeline.ioSurfaceFrames &+= 1
            if seenSurfaces.contains(id) { snapshot.pipeline.ioSurfaceReuseCount &+= 1 }
            seenSurfaces.append(id)
            if seenSurfaces.count > 256 { seenSurfaces.removeFirst() }
        }
    }

    func recordPresentation(at presented: Double, submitted: Double, captureTime: Double?) {
        lock.lock()
        defer { lock.unlock() }
        snapshot.pipeline.renderToPresentMilliseconds = FrameTelemetry.milliseconds(from: submitted, to: presented)
        snapshot.pipeline.captureToPresentMilliseconds = FrameTelemetry.milliseconds(from: captureTime, to: presented)
    }

    func sampleMemory() {
        let bytes = PipelineMeasurements.residentMemory()
        lock.lock()
        snapshot.pipeline.residentMemoryBytes = bytes
        lock.unlock()
    }

    func recordFrameSubmitted(at time: CFTimeInterval, inputFrame: VideoFrame?) {
        lock.lock()
        defer { lock.unlock() }

        if let previousFrameStart, time - previousFrameStart > (1.0 / 60.0) * 1.5 {
            snapshot.droppedFrameEstimate += UInt64((time - previousFrameStart) * 60.0) - 1
        }
        previousFrameStart = time
        snapshot.renderedFrameCount += 1
        framesInWindow += 1

        let elapsed = time - frameWindowStart
        if elapsed >= 0.5 {
            snapshot.frameRate = Double(framesInWindow) / elapsed
            frameWindowStart = time
            framesInWindow = 0
        }

        if let inputFrame {
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let age = CMTimeSubtract(hostNow, inputFrame.hostReceiveTime)
            snapshot.inputHealth = .evaluate(ageSeconds: CMTimeGetSeconds(age), qualityLost: inputFrame.quality == .lost)
            snapshot.inputAgeMilliseconds = max(0, CMTimeGetSeconds(age) * 1_000)
        } else {
            snapshot.inputHealth = .missing
            snapshot.inputAgeMilliseconds = 0
        }
        if snapshot.inputHealth != .active {
            snapshot.pipeline.captureToEncodeMilliseconds = nil
            snapshot.pipeline.transportMilliseconds = nil
            snapshot.pipeline.captureToReceiveMilliseconds = nil
            snapshot.pipeline.receiveToDecodeMilliseconds = nil
            snapshot.pipeline.decodeMilliseconds = nil
            snapshot.pipeline.decodeToRenderMilliseconds = nil
            snapshot.pipeline.textureImportMilliseconds = nil
        }
    }

    func recordGPUCompletion(start: CFTimeInterval, end: CFTimeInterval) {
        guard end >= start, start > 0 else { return }
        lock.lock()
        snapshot.gpuFrameMilliseconds = (end - start) * 1_000
        lock.unlock()
    }

    func read() -> RealtimeMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
