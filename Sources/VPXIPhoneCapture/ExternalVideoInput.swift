#if os(iOS)
import CoreVideo
import CoreMedia
import Foundation
import VPXCaptureProtocol

/// Native-only input for a producer that owns the camera. Submitted buffers
/// must remain read-only while retained by the encoder.
public final class ExternalVideoInput: @unchecked Sendable {
    private struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let time: UInt64
        let metadata: CaptureCameraMetadata?
    }

    private let queue = DispatchQueue(label: "studio.vpx.external-video")
    private let slots = DispatchSemaphore(value: 3)
    private let lock = NSLock()
    private var active = true
    private var keyFrameRequested = true
    private var sequence: UInt64 = 0
    private var lastTimestamp: UInt64?
    private let encoder: IPhoneHEVCVideoEncoder

    init(profile: CaptureVideoProfile, send: @escaping @Sendable (CaptureEncodedVideoFrame) throws -> Void,
         onError: @escaping @Sendable (Error) -> Void) throws {
        encoder = try IPhoneHEVCVideoEncoder(profile: profile)
        encoder.onEncodedFrame = { [weak self] frame in
            guard let self else { return }
            do {
                try lock.withLock { if active { try send(frame) } }
            } catch { onError(error) }
        }
        encoder.onError = onError
    }

    /// Accepts an AVCapture video sample on its session synchronization clock.
    /// Camera retains ownership of the session. Color tags are copied from the
    /// image buffer when the producer does not supply richer metadata.
    @discardableResult
    public func submit(_ sample: CMSampleBuffer, synchronizationClock: CMClock,
                       cameraID: String, metadata: CaptureCameraMetadata? = nil) -> Bool {
        guard CMSampleBufferDataIsReady(sample), let image = CMSampleBufferGetImageBuffer(sample) else { return false }
        let hostTime = CMSyncConvertTime(sample.presentationTimeStamp, from: synchronizationClock,
                                         to: CMClockGetHostTimeClock())
        let nanos = CMTimeConvertScale(hostTime, timescale: 1_000_000_000, method: .roundTowardZero)
        guard nanos.isNumeric, nanos.epoch == 0, nanos.value > 0 else { return false }
        func colorTag(_ key: CFString) -> String? {
            CVBufferCopyAttachment(image, key, nil) as? String
        }
        let tags = metadata ?? CaptureCameraMetadata(cameraID: cameraID, source: "external",
            colorPrimaries: colorTag(kCVImageBufferColorPrimariesKey),
            transferFunction: colorTag(kCVImageBufferTransferFunctionKey),
            yCbCrMatrix: colorTag(kCVImageBufferYCbCrMatrixKey))
        return submit(image, hostTimeNanoseconds: UInt64(nanos.value), metadata: tags)
    }

    /// Returns false when stopped or backpressured. The caller retains control
    /// of its AVCapture session and can discard the frame without blocking.
    @discardableResult
    public func submit(_ buffer: CVPixelBuffer, hostTimeNanoseconds: UInt64,
                       metadata: CaptureCameraMetadata? = nil) -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard active, hostTimeNanoseconds > 0, lastTimestamp.map({ hostTimeNanoseconds > $0 }) ?? true,
              slots.wait(timeout: .now()) == .success else { return false }
        lastTimestamp = hostTimeNanoseconds
        let frame = Frame(buffer: buffer, time: hostTimeNanoseconds, metadata: metadata)
        queue.async { [self] in
            defer { slots.signal() }
            guard lock.withLock({ active }) else { return }
            let force = lock.withLock {
                let requested = keyFrameRequested
                keyFrameRequested = false
                return requested
            }
            if force { encoder.requestKeyFrame() }
            sequence &+= 1
            do {
                try encoder.encode(pixelBuffer: frame.buffer,
                    header: CaptureVideoFrameHeader(sequence: sequence, captureTimeNanoseconds: frame.time,
                        width: UInt32(CVPixelBufferGetWidth(frame.buffer)), height: UInt32(CVPixelBufferGetHeight(frame.buffer)),
                        codec: "hvc1", isKeyFrame: false, cameraMetadata: frame.metadata))
            } catch {
                encoder.onError?(error)
            }
        }
        return true
    }

    func requestKeyFrame() { lock.withLock { keyFrameRequested = true } }

    func stop() {
        lock.withLock { active = false }
        queue.async { [self] in encoder.invalidate() }
    }
}
#endif
