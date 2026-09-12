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

    init(hello: CaptureNodeHello) {
        descriptor = DeviceDescriptor(
            id: hello.nodeID,
            displayName: hello.displayName,
            capabilities: Self.deviceCapabilities(from: hello.capabilities)
        )
        decoder.onDecodedFrame = { [weak self] header, pixelBuffer in
            self?.publish(header: header, pixelBuffer: pixelBuffer)
        }
        decoder.onError = { [weak self] error in
            self?.onFailure?(error)
        }
    }

    func start() throws {}

    func stop() {
        decoder.completeFrames()
        decoder.invalidate()
    }

    func receive(_ encodedFrame: CaptureEncodedVideoFrame) throws {
        try decoder.decode(encodedFrame)
    }

    private func publish(header: CaptureVideoFrameHeader, pixelBuffer: CVPixelBuffer) {
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
                quality: .nominal
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
