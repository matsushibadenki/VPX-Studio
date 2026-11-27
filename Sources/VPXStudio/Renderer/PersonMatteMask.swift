import CoreMedia
import Metal
import Vision

// Texture contents are immutable after upload and safe to share with the render queue.
struct PersonMatteMask: @unchecked Sendable {
    struct FrameKey: Equatable, Sendable {
        let source: UUID
        let generation: UUID?
        let sequence: UInt64
        let received: Double
        let width: Int
        let height: Int

        init?(frame: VideoFrame, source: UUID?) {
            let received = CMTimeGetSeconds(frame.hostReceiveTime)
            guard let source, received.isFinite else { return nil }
            self.source = source
            generation = frame.telemetry.sourceGeneration
            sequence = frame.identifier
            self.received = received
            width = CVPixelBufferGetWidth(frame.pixelBuffer)
            height = CVPixelBufferGetHeight(frame.pixelBuffer)
        }

        func acceptsMask(width: Int, height: Int) -> Bool {
            guard width > 0, height > 0 else { return false }
            // Allow up to one mask pixel of aspect-ratio rounding.
            return abs(Double(self.width) * Double(height) - Double(self.height) * Double(width))
                <= Double(max(self.width, self.height))
        }
    }

    let key: FrameKey
    let texture: MTLTexture

    func matches(_ frame: VideoFrame, source: UUID?, now: Double) -> Bool {
        FrameKey(frame: frame, source: source) == key &&
            now >= key.received && now - key.received <= 0.15 &&
            texture.pixelFormat == .r8Unorm && key.acceptsMask(width: texture.width, height: texture.height)
    }
}

/// At most one Vision request in flight. A late result never delays or replaces the live frame.
final class PersonMatteWorker: @unchecked Sendable {
    private struct Input: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let key: PersonMatteMask.FrameKey
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "studio.vpx.person-matte", qos: .utility)
    private var busy = false
    private var lastRequested: PersonMatteMask.FrameKey?
    private var latest: PersonMatteMask?

    init(device: MTLDevice) { self.device = device }

    func mask(for frame: VideoFrame, source: UUID?, now: Double) -> PersonMatteMask? {
        guard let key = PersonMatteMask.FrameKey(frame: frame, source: source),
              now >= key.received, now - key.received <= 0.15, frame.quality != .lost else { return nil }
        return lock.withLock {
            if let latest, latest.key == key { return latest }
            guard !busy, lastRequested != key else { return nil }
            lastRequested = key
            busy = true
            let input = Input(buffer: frame.pixelBuffer, key: key)
            queue.async { [self] in
                let result = generate(input)
                lock.withLock { latest = result; busy = false }
            }
            return nil
        }
    }

    private func generate(_ input: Input) -> PersonMatteMask? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        // Use the full, unrotated pixel raster that Metal imports.
        let handler = VNImageRequestHandler(cvPixelBuffer: input.buffer, orientation: .up)
        do { try handler.perform([request]) } catch { return nil }
        guard let mask = request.results?.first?.pixelBuffer,
              CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        guard input.key.acceptsMask(width: width, height: height) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(mask) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: CVPixelBufferGetBytesPerRow(mask))
        return PersonMatteMask(key: input.key, texture: texture)
    }
}
