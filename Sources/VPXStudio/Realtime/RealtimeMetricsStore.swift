import CoreMedia
import Foundation
import QuartzCore

struct RealtimeMetricsSnapshot: Sendable {
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
            snapshot.inputAgeMilliseconds = max(0, CMTimeGetSeconds(age) * 1_000)
        } else {
            snapshot.inputAgeMilliseconds = 0
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
