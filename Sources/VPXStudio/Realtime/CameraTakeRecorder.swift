import AVFoundation
import Foundation

/// One recording owns one writer. Capture callbacks never wait for disk or encoding.
final class CameraTakeRecorder: @unchecked Sendable {
    enum Failure: Error { case noFrames, writerFailed, formatChanged, destinationExists }
    struct Statistics: Codable, Sendable {
        let sourceID: UUID
        var frames = 0
        var dropped = 0
        var width = 0
        var height = 0
        var pixelFormat: UInt32 = 0
    }

    private struct Sample: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let time: CMTime
    }

    private let queue = DispatchQueue(label: "studio.vpx.take-writer", qos: .userInitiated)
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 4)
    private var accepting = true
    private var overflow = 0
    private var failed = false
    var hasFailed: Bool { lock.withLock { failed } }
    private var stats: Statistics
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var start: CMTime?
    private var last: CMTime?
    private var failure: (any Error)?
    private let request: TakeSnapshotRequest
    private let parent: URL
    private let scoped: Bool
    private let staging: URL
    private let destination: URL

    init(request: TakeSnapshotRequest, parent: URL, sourceID: UUID) throws {
        stats = Statistics(sourceID: sourceID)
        self.request = request
        self.parent = parent
        staging = parent.appendingPathComponent(".vpx-recording-\(request.manifest.id)", isDirectory: true)
        destination = parent.appendingPathComponent("VPX-Take-\(request.manifest.id)", isDirectory: true)
        let didScope = parent.startAccessingSecurityScopedResource()
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            if didScope { parent.stopAccessingSecurityScopedResource() }
            throw error
        }
        scoped = didScope
    }

    deinit {
        try? FileManager.default.removeItem(at: staging)
        if scoped { parent.stopAccessingSecurityScopedResource() }
    }

    func submit(_ frame: VideoFrame) {
        lock.withLock {
            guard accepting, !failed else { return }
            guard slots.wait(timeout: .now()) == .success else { overflow += 1; return }
            let sample = Sample(buffer: frame.pixelBuffer, time: frame.hostReceiveTime)
            queue.async { [self] in
                defer { slots.signal() }
                guard failure == nil else { return }
                do { try append(sample) }
                catch {
                    failure = error
                    lock.withLock { failed = true }
                    writer?.cancelWriting()
                }
            }
        }
    }

    private func append(_ sample: Sample) throws {
        guard sample.time.isNumeric, last.map({ CMTimeCompare(sample.time, $0) > 0 }) ?? true else {
            stats.dropped += 1; return
        }
        let width = CVPixelBufferGetWidth(sample.buffer), height = CVPixelBufferGetHeight(sample.buffer)
        let format = CVPixelBufferGetPixelFormatType(sample.buffer)
        if writer == nil {
            let writer = try AVAssetWriter(outputURL: staging.appendingPathComponent("camera.mov"), fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure.writerFailed }
            writer.add(input)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.startWriting() else { throw writer.error ?? Failure.writerFailed }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer; self.input = input; self.adaptor = adaptor; start = sample.time
            stats.width = width; stats.height = height; stats.pixelFormat = format
        }
        guard width == stats.width, height == stats.height, format == stats.pixelFormat else { throw Failure.formatChanged }
        guard let writer, writer.status == .writing, let input, let adaptor, let start else {
            throw writer?.error ?? Failure.writerFailed
        }
        guard input.isReadyForMoreMediaData else { stats.dropped += 1; return }
        guard adaptor.append(sample.buffer, withPresentationTime: CMTimeSubtract(sample.time, start)) else {
            throw writer.error ?? Failure.writerFailed
        }
        last = sample.time; stats.frames += 1
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                guard accepting else { continuation.resume(throwing: Failure.writerFailed); return }
                accepting = false
                let dropped = overflow
                queue.async { [self] in
                    stats.dropped += dropped
                    if let failure { continuation.resume(throwing: failure); return }
                    guard let writer, let input, stats.frames > 0 else {
                        writer?.cancelWriting(); continuation.resume(throwing: Failure.noFrames); return
                    }
                    input.markAsFinished()
                    writer.finishWriting { [self] in
                        queue.async { [self] in
                            do {
                                guard self.writer?.status == .completed else { throw self.writer?.error ?? Failure.writerFailed }
                                continuation.resume(returning: try publish())
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                }
            }
        }
    }

    private func publish() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try request.diagnostics.write(to: staging.appendingPathComponent("diagnostics.json"))
        try encoder.encode(stats).write(to: staging.appendingPathComponent("recording.json"))
        if let calibration = request.calibration { try calibration.write(to: staging.appendingPathComponent("calibration.json")) }
        var manifest = request.manifest
        guard let provenance = manifest.provenance else { throw Failure.writerFailed }
        manifest.name = "VPX Take"
        manifest.provenance = .init(kind: .recording, software: provenance.software, devices: provenance.devices, calibration: provenance.calibration)
        manifest.assets += [.init(role: .camera, relativePath: "camera.mov"), .init(role: .diagnostics, relativePath: "recording.json")]
        try manifest.sealAssets(in: staging)
        try manifest.save(to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }
}
