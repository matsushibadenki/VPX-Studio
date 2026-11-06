import CoreMedia
import CoreVideo
import Foundation

struct BenchmarkFixture: Codable, Equatable, Sendable {
    struct Pose: Codable, Equatable, Sendable {
        let frame: Int
        let offsetNanoseconds: UInt64
        let translationMeters: [Float]
    }

    let id: String
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let poses: [Pose]

    static let standard = BenchmarkFixture(id: "vpx-fixed-pattern-pose-v1", width: 640, height: 360,
        framesPerSecond: 60, poses: (0..<120).map { index in
            Pose(frame: index, offsetNanoseconds: UInt64(index) * 1_000_000_000 / 60,
                 translationMeters: [Float(index % 60) / 60, 1.5, 0])
        })
}

struct BenchmarkResult: Codable {
    enum Status: String, Codable { case running, completed, cancelled, failed }
    let fixture: BenchmarkFixture
    let startedAt: Date
    var completedAt: Date?
    var status: Status = .running
    var deliveredFrames = 0
    var replayedPoses = 0
    var lastPose: BenchmarkFixture.Pose?
    var initialMeasurements = RealtimeMetricsSnapshot()
    var measurements: [RealtimeMetricsSnapshot] = []
}

/// A finite, deterministic image/Pose replay through the same source mailbox and renderer.
/// Mutable playback state is confined to queue; callbacks are configured before start.
final class BenchmarkVideoSource: VideoSource, @unchecked Sendable {
    let descriptor = DeviceDescriptor(id: UUID(), displayName: "VPX Benchmark · 640×360 / 60p", capabilities: [.video, .pose])
    let fixture = BenchmarkFixture.standard
    var onFrame: ((VideoFrame) -> Void)?
    var onPose: ((BenchmarkFixture.Pose, UInt64) -> Void)?
    var onComplete: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "jp.vpxstudio.benchmark")
    private var timer: DispatchSourceTimer?
    private var index = 0
    private var pool: CVPixelBufferPool?

    init() throws {
        let status = CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: fixture.width,
            kCVPixelBufferHeightKey: fixture.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
    }

    func start() throws {
        queue.sync {
            timer?.cancel()
            index = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fixture.framesPerSecond))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
    }

    deinit { timer?.cancel() }

    private func tick() {
        guard index < fixture.poses.count else {
            timer?.cancel()
            timer = nil
            onComplete?()
            return
        }
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            let frame = try makeFrame(index: index, hostNanoseconds: now)
            onFrame?(frame)
            onPose?(fixture.poses[index], now)
            index += 1
        } catch {
            timer?.cancel()
            timer = nil
            onFailure?(error)
        }
    }

    func makeFrame(index: Int, hostNanoseconds: UInt64) throws -> VideoFrame {
        guard fixture.poses.indices.contains(index), let pool else { throw CocoaError(.coderInvalidValue) }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw CocoaError(.coderInvalidValue) }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CocoaError(.coderInvalidValue) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<fixture.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<fixture.width {
                let red = UInt32((x + index * 3) % 256)
                let green = UInt32(y % 256)
                let blue = UInt32((x / 40 + y / 40) % 2 == 0 ? 32 : 224)
                row[x] = 0xFF000000 | red << 16 | green << 8 | blue
            }
        }
        let time = CMTime(value: Int64(clamping: hostNanoseconds), timescale: 1_000_000_000)
        let captured = Double(hostNanoseconds) / 1_000_000_000
        let received = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        return VideoFrame(identifier: UInt64(index), captureTime: time, hostReceiveTime: time,
            colorMetadata: .init(colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2", yCbCrMatrix: nil),
            pixelBuffer: buffer, quality: .nominal, telemetry: FrameTelemetry(captured: captured, received: received))
    }
}
