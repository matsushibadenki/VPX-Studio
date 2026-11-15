import AVFoundation

final class TakeMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: Error { case unavailable, permissionDenied, startFailed }
    private let queue = DispatchQueue(label: "studio.vpx.take-microphone")
    private let session = AVCaptureSession()
    private let recorder: CameraTakeRecorder

    init(recorder: CameraTakeRecorder) { self.recorder = recorder }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let device = AVCaptureDevice.default(for: .audio) else { throw Failure.unavailable }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw Failure.unavailable }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.startRunning()
                    guard session.isRunning else { throw Failure.startFailed }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { return }
        let time = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        recorder.submitAudio(sampleBuffer, at: time)
    }
}
