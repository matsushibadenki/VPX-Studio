@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum VideoSourceError: LocalizedError {
    case noCameraAvailable
    case cameraAccessDenied
    case cannotCreateInput

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable: "No video camera is available."
        case .cameraAccessDenied: "Camera access has not been granted."
        case .cannotCreateInput: "Unable to create a camera input."
        }
    }
}

/// AVFoundation adapter for a local UVC camera or Continuity Camera.
///
/// It only produces common VideoFrame values; the Metal frame graph owns texture
/// conversion, compositing, and any presentation decision.
final class MacCameraVideoSource: NSObject, VideoSource {
    let descriptor: DeviceDescriptor
    var onFrame: ((VideoFrame) -> Void)?

    private let captureSession = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "jp.vpxstudio.camera-capture", qos: .userInteractive)
    private var nextFrameIdentifier: UInt64 = 0

    init(device: AVCaptureDevice? = AVCaptureDevice.default(for: .video)) throws {
        guard let device else { throw VideoSourceError.noCameraAvailable }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw VideoSourceError.cameraAccessDenied
        }

        descriptor = DeviceDescriptor(
            id: UUID(),
            displayName: device.localizedName,
            capabilities: [.video]
        )
        super.init()

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .high

        guard let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            throw VideoSourceError.cannotCreateInput
        }
        captureSession.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard captureSession.canAddOutput(output) else {
            throw VideoSourceError.cannotCreateInput
        }
        captureSession.addOutput(output)
    }

    func start() throws {
        guard !captureSession.isRunning else { return }
        captureSession.startRunning()
    }

    func stop() {
        captureSession.stopRunning()
    }
}

extension MacCameraVideoSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        nextFrameIdentifier &+= 1
        onFrame?(
            VideoFrame(
                identifier: nextFrameIdentifier,
                captureTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                hostReceiveTime: CMClockGetTime(CMClockGetHostTimeClock()),
                colorMetadata: VideoColorMetadata.read(from: pixelBuffer),
                pixelBuffer: pixelBuffer,
                quality: .nominal
            )
        )
    }
}
