import Foundation
import Darwin

/// All times are seconds in the Host monotonic clock domain. Nil means unknown.
struct FrameTelemetry: Sendable {
    var captured: Double?
    var received: Double?
    var encodeCompleted: Double?
    var decodeStarted: Double?
    var decodeCompleted: Double?
    var knownCPUCopyCount: UInt64 = 0
    var knownCPUCopyBytes: UInt64 = 0

    static func milliseconds(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end, start.isFinite, end.isFinite, end >= start else { return nil }
        return (end - start) * 1_000
    }
}

struct PipelineMeasurements: Codable, Sendable {
    var captureToEncodeMilliseconds: Double?
    var transportMilliseconds: Double?
    var captureToReceiveMilliseconds: Double?
    var receiveToDecodeMilliseconds: Double?
    var decodeMilliseconds: Double?
    var decodeToRenderMilliseconds: Double?
    var textureImportMilliseconds: Double?
    var renderToPresentMilliseconds: Double?
    var captureToPresentMilliseconds: Double?
    var residentMemoryBytes: UInt64?
    var observedFrames: UInt64 = 0
    var knownCPUCopyCount: UInt64 = 0
    var knownCPUCopyBytes: UInt64 = 0
    var pixelBufferReuseCount: UInt64 = 0
    var ioSurfaceFrames: UInt64 = 0
    var ioSurfaceReuseCount: UInt64 = 0

    static func residentMemory() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
