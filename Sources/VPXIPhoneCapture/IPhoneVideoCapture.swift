#if os(iOS)
@preconcurrency import AVFoundation
import VPXCaptureProtocol

/// Video-only mode owns the camera exclusively; ARSession must be paused.
final class IPhoneVideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onSample: ((CaptureVideoSample) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.vpxstudio.avcapture")
    private var sequence: UInt64 = 0
    private var cameraID = ""
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .hd1920x1080
                if session.inputs.isEmpty {
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        throw CaptureTransportCodecError.malformedPacket
                    }
                    cameraID=camera.uniqueID
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard session.canAddInput(input) else { throw CaptureTransportCodecError.malformedPacket }
                    session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames=true
                    output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(output) else { throw CaptureTransportCodecError.malformedPacket }
                    session.addOutput(output)
                }
            } catch { onFailure?(error); return }
            session.startRunning()
        }
    }
    func stop() { queue.sync { session.stopRunning() } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image=CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let seconds=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard seconds.isFinite, seconds >= 0 else { return }
        sequence &+= 1
        let header=CaptureVideoFrameHeader(sequence: sequence, captureTimeNanoseconds: UInt64(seconds*1_000_000_000),
            width: UInt32(CVPixelBufferGetWidth(image)), height: UInt32(CVPixelBufferGetHeight(image)),
            codec: "raw-cv-pixel-buffer", isKeyFrame: true,
            cameraMetadata: Self.metadata(image, cameraID: cameraID, source: "avcapture"))
        onSample?(CaptureVideoSample(header: header, pixelBuffer: image))
    }
    static func metadata(_ image: CVPixelBuffer, cameraID: String, source: String, intrinsics: [Float]? = nil) -> CaptureCameraMetadata {
        func value(_ key: CFString) -> String? { CVBufferCopyAttachment(image, key, nil) as? String }
        return CaptureCameraMetadata(cameraID: cameraID, source: source,
            colorPrimaries: value(kCVImageBufferColorPrimariesKey), transferFunction: value(kCVImageBufferTransferFunctionKey),
            yCbCrMatrix: value(kCVImageBufferYCbCrMatrixKey), intrinsics: intrinsics)
    }
}
#endif
