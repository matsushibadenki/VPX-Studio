import AVFoundation
import Foundation
import VideoToolbox

/// One recording owns one writer. Capture callbacks never wait for disk or encoding.
final class CameraTakeRecorder: @unchecked Sendable {
    enum Failure: Error { case insufficientStorage, requires10BitInput, invalid10BitOutput, noAudio, noFrames, writerFailed, formatChanged, destinationExists }
    struct Statistics: Codable, Sendable {
        let sourceID: UUID
        var frames = 0
        var dropped = 0
        var width = 0
        var height = 0
        var pixelFormat: UInt32 = 0
        var peakVideoWriteMilliseconds: Double?
        var encodedBitDepth: Int?
        var audioBuffers: Int?
        var audioDropped: Int?
    }

    private struct Sample: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let time: CMTime
        let auxiliary: TakeAuxiliaryFrame?
        let matte: TakeMatteCopy?
    }

    private let queue = DispatchQueue(label: "studio.vpx.take-writer", qos: .userInitiated)
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 4)
    private var accepting = true
    private var overflow = 0
    private var writerDrops = 0
    private var lowStorage = false
    private var lastStorageCheck: UInt64 = 0
    private static let storageReserve: UInt64 = 256 * 1024 * 1024

    struct Health {
        var lowStorage = false
        var dropped = 0
        var writeDelayed = false
        var secondsRemaining: Int?
    }

    private var writeDelayed = false
    private var delayScore = 0
    private var secondsRemaining: Int?
    private var previousStorageSample: (time: UInt64, bytes: UInt64)?
    private var bytesPerSecond: Double?

    var health: Health {
        lock.withLock {
            Health(lowStorage: lowStorage, dropped: overflow + writerDrops,
                writeDelayed: writeDelayed, secondsRemaining: secondsRemaining)
        }
    }

    private static func freeBytes(at directory: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let bytes = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return bytes.uint64Value
    }

    private func checkStorage() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastStorageCheck >= 1_000_000_000 {
            lastStorageCheck = now
            let files = [movieName, "matte.f16le", "depth.bin", "frames.jsonl"]
            let bytes = files.reduce(UInt64(0)) { sum, file in
                let path = staging.appendingPathComponent(file).path
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
                return sum + (size?.uint64Value ?? 0)
            }
            if let previous = previousStorageSample, bytes > previous.bytes {
                let rate = Double(bytes - previous.bytes) * 1e9 / Double(now - previous.time)
                bytesPerSecond = bytesPerSecond.map { $0 * 0.75 + rate * 0.25 } ?? rate
                previousStorageSample = (now, bytes)
            } else if previousStorageSample == nil {
                previousStorageSample = (now, bytes)
            }
            if let free = Self.freeBytes(at: staging) {
                let reserve = max(Double(Self.storageReserve), (bytesPerSecond ?? 0) * 5)
                let remaining = bytesPerSecond.map { min(86_400, max(0, (Double(free) - reserve) / $0)) }
                lock.withLock {
                    secondsRemaining = remaining.map { Int($0) }
                    if Double(free) < reserve { lowStorage = true }
                }
            } else {
                lock.withLock { secondsRemaining = nil }
            }
        }
        return !health.lowStorage
    }

    private func measureVideoWrite(since enqueued: UInt64) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - enqueued) / 1e6
        stats.peakVideoWriteMilliseconds = max(stats.peakVideoWriteMilliseconds ?? 0, milliseconds)
        delayScore = milliseconds >= 100 ? min(10, delayScore + 3) : max(0, delayScore - 1)
        lock.withLock {
            if delayScore >= 9 { writeDelayed = true }
            else if delayScore == 0 { writeDelayed = false }
        }
    }

    private func dropWriterFrame() {
        stats.dropped += 1
        lock.withLock { writerDrops += 1 }
    }

    private var failed = false
    var hasFailed: Bool { lock.withLock { failed } }
    private var stats: Statistics
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var start: CMTime?
    private var last: CMTime?
    private var failure: (any Error)?
    let composite: Bool
    let preserve10Bit: Bool
    private var audioInput: AVAssetWriterInput?
    private let audioSlots = DispatchSemaphore(value: 16)
    private var audioOverflow = 0
    private var lastAudio: CMTime?
    private struct AudioSample: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let time: CMTime
    }
    private var movieName: String { composite ? "composite.mov" : "camera.mov" }
    private let auxiliaryTracks: TakeAuxiliaryTracks?
    private let sceneSnapshot: TakeSceneSnapshot?
    private let request: TakeSnapshotRequest
    private let parent: URL
    private let scoped: Bool
    private let staging: URL
    private let destination: URL

    init(request: TakeSnapshotRequest, parent: URL, sourceID: UUID, composite: Bool = false, preserve10Bit: Bool = false,
         sceneSnapshot: TakeSceneSnapshot? = nil) throws {
        self.sceneSnapshot = sceneSnapshot
        self.preserve10Bit = preserve10Bit
        self.composite = composite
        stats = Statistics(sourceID: sourceID)
        if composite { stats.audioBuffers = 0; stats.audioDropped = 0 }
        self.request = request
        self.parent = parent
        staging = parent.appendingPathComponent(".vpx-recording-\(request.manifest.id)", isDirectory: true)
        destination = parent.appendingPathComponent("VPX-Take-\(request.manifest.id)", isDirectory: true)
        let didScope = parent.startAccessingSecurityScopedResource()
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
            if let free = Self.freeBytes(at: parent), free < Self.storageReserve { throw Failure.insufficientStorage }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            if didScope { parent.stopAccessingSecurityScopedResource() }
            throw error
        }
        auxiliaryTracks = composite ? TakeAuxiliaryTracks(directory: staging) : nil
        scoped = didScope
    }

    deinit {
        try? FileManager.default.removeItem(at: staging)
        if scoped { parent.stopAccessingSecurityScopedResource() }
    }

    func dropVideoFrame() { lock.withLock { if accepting { overflow += 1 } } }

    func submit(_ frame: VideoFrame) {
        submitVideo(frame.pixelBuffer, at: frame.hostReceiveTime)
    }

    func submitVideo(_ buffer: CVPixelBuffer, at time: CMTime,
                     auxiliary: TakeAuxiliaryFrame? = nil, matte: TakeMatteCopy? = nil) {
        lock.withLock {
            guard accepting, !failed, !lowStorage else { return }
            guard slots.wait(timeout: .now()) == .success else { overflow += 1; return }
            let enqueued = DispatchTime.now().uptimeNanoseconds
            let sample = Sample(buffer: buffer, time: time, auxiliary: auxiliary, matte: matte)
            queue.async { [self] in
                defer { slots.signal() }
                guard failure == nil, checkStorage() else { return }
                defer { measureVideoWrite(since: enqueued) }
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
            dropWriterFrame(); return
        }
        let width = CVPixelBufferGetWidth(sample.buffer), height = CVPixelBufferGetHeight(sample.buffer)
        let format = CVPixelBufferGetPixelFormatType(sample.buffer)
        if preserve10Bit {
            guard format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange else { throw Failure.requires10BitInput }
        }
        if writer == nil {
            let writer = try AVAssetWriter(outputURL: staging.appendingPathComponent(movieName), fileType: .mov)
            var settings: [String: Any] = [
                AVVideoCodecKey: preserve10Bit ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height
            ]
            if preserve10Bit {
                if composite {
                    settings[AVVideoColorPropertiesKey] = [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                    ]
                }
                settings[AVVideoCompressionPropertiesKey] = [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel
                ]
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw Failure.writerFailed }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure.writerFailed }
            writer.add(input)
            if composite {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
                ])
                audio.expectsMediaDataInRealTime = true
                guard writer.canAdd(audio) else { throw Failure.writerFailed }
                writer.add(audio)
                audioInput = audio
            }
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
        guard input.isReadyForMoreMediaData else { dropWriterFrame(); return }
        let pts = CMTimeSubtract(sample.time, start)
        guard adaptor.append(sample.buffer, withPresentationTime: pts) else {
            throw writer.error ?? Failure.writerFailed
        }
        try auxiliaryTracks?.append(frame: sample.auxiliary, matte: sample.matte, index: stats.frames, time: pts)
        last = sample.time; stats.frames += 1
    }

    func submitAudio(_ buffer: CMSampleBuffer, at hostTime: CMTime) {
        lock.withLock {
            guard composite, accepting, !failed, !lowStorage else { return }
            guard audioSlots.wait(timeout: .now()) == .success else { audioOverflow += 1; return }
            let sample = AudioSample(buffer: buffer, time: hostTime)
            queue.async { [self] in
                defer { audioSlots.signal() }
                guard failure == nil, checkStorage() else { return }
                do { try appendAudio(sample) }
                catch {
                    failure = error
                    lock.withLock { failed = true }
                    writer?.cancelWriting()
                }
            }
        }
    }

    private func appendAudio(_ sample: AudioSample) throws {
        guard let start, let audioInput else { return }
        let time = CMTimeSubtract(sample.time, start)
        guard time.isNumeric, time >= .zero, lastAudio.map({ time > $0 }) ?? true,
              audioInput.isReadyForMoreMediaData else {
            stats.audioDropped? += 1
            return
        }
        let timing = try sample.buffer.sampleTimingInfos()
        let shift = CMTimeSubtract(time, sample.buffer.presentationTimeStamp)
        let adjusted = timing.map { item in
            CMSampleTimingInfo(duration: item.duration,
                presentationTimeStamp: CMTimeAdd(item.presentationTimeStamp, shift),
                decodeTimeStamp: item.decodeTimeStamp.isNumeric ? CMTimeAdd(item.decodeTimeStamp, shift) : .invalid)
        }
        let buffer = try CMSampleBuffer(copying: sample.buffer, withNewTiming: adjusted)
        guard audioInput.append(buffer) else { throw writer?.error ?? Failure.writerFailed }
        lastAudio = time
        stats.audioBuffers? += 1
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                guard accepting else { continuation.resume(throwing: Failure.writerFailed); return }
                accepting = false
                let dropped = overflow
                let audioDropped = audioOverflow
                queue.async { [self] in
                    stats.dropped += dropped
                    stats.audioDropped? += audioDropped
                    if let failure { continuation.resume(throwing: failure); return }
                    guard let writer, let input, stats.frames > 0 else {
                        writer?.cancelWriting()
                        continuation.resume(throwing: health.lowStorage ? Failure.insufficientStorage : Failure.noFrames)
                        return
                    }
                    if composite && stats.audioBuffers == 0 {
                        writer.cancelWriting(); continuation.resume(throwing: Failure.noAudio); return
                    }
                    input.markAsFinished()
                    audioInput?.markAsFinished()
                    writer.finishWriting { [self] in
                        queue.async { [self] in
                            guard self.writer?.status == .completed else {
                                continuation.resume(throwing: self.writer?.error ?? Failure.writerFailed)
                                return
                            }
                            if preserve10Bit {
                                let url = staging.appendingPathComponent(movieName)
                                Task {
                                    do {
                                        try await Self.verify10BitMovie(at: url)
                                        queue.async { [self] in
                                            stats.encodedBitDepth = 10
                                            continuation.resume(with: Result { try publish() })
                                        }
                                    } catch { continuation.resume(throwing: error) }
                                }
                            } else {
                                continuation.resume(with: Result { try publish() })
                            }
                        }
                    }
                }
            }
        }
    }

    private static func verify10BitMovie(at url: URL) async throws {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Failure.invalid10BitOutput }
        let formats = try await track.load(.formatDescriptions)
        guard !formats.isEmpty else { throw Failure.invalid10BitOutput }
        for format in formats {
            let extensions = CMFormatDescriptionGetExtensions(format) as NSDictionary?
            let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Data]
            // HEVCDecoderConfigurationRecord stores luma/chroma bit depth minus eight.
            guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
                  let record = atoms?["hvcC"], record.count >= 23, record[0] == 1,
                  record[17] & 7 == 2, record[18] & 7 == 2 else { throw Failure.invalid10BitOutput }
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
        manifest.assets += [.init(role: composite ? .composite : .camera, relativePath: movieName), .init(role: .diagnostics, relativePath: "recording.json")]
        manifest.assets += try auxiliaryTracks?.close() ?? []
        if let sceneSnapshot {
            let path = "scene.vpx.json"
            try JSONEncoder().encode(sceneSnapshot).write(to: staging.appendingPathComponent(path))
            manifest.assets.append(.init(role: .scene, relativePath: path))
        }
        try manifest.sealAssets(in: staging)
        try manifest.save(to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }
}
