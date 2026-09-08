@preconcurrency import AVFoundation
import Observation

enum StudioMode: String, CaseIterable, Identifiable {
    case build
    case calibrate
    case rehearse
    case live
    case record
    case review

    var id: Self { self }

    var localizationKey: LocalizationKey {
        switch self {
        case .build: .build
        case .calibrate: .calibrate
        case .rehearse: .rehearse
        case .live: .live
        case .record: .record
        case .review: .review
        }
    }
}

enum StudioStatus {
    case preparingMetalRenderer
    case metalPreviewActive
    case previewStopped
    case cameraAccessNotGranted
    case liveCameraPreviewActive
    case error(String)

    @MainActor
    func text(_ localization: LocalizationStore) -> String {
        switch self {
        case .preparingMetalRenderer: localization.text(.preparingMetalRenderer)
        case .metalPreviewActive: localization.text(.metalPreviewActive)
        case .previewStopped: localization.text(.previewStopped)
        case .cameraAccessNotGranted: localization.text(.cameraAccessNotGranted)
        case .liveCameraPreviewActive: localization.text(.liveCameraPreviewActive)
        case .error(let message): message
        }
    }
}

@MainActor @Observable
final class StudioModel {
    var mode: StudioMode = .build
    var selectedSourceName = ""
    var trackingQuality: StreamQuality = .lost
    var rendererStatus: StudioStatus = .preparingMetalRenderer
    var frameRate = 0.0
    var latencyMilliseconds = 0.0
    var gpuFrameMilliseconds = 0.0
    var droppedFrameEstimate: UInt64 = 0
    var inputColorMetadata = ""
    var isRecording = false
    var chromaKeyEnabled = false
    var chromaGreenThreshold: Float = 0.12
    var chromaGreenSoftness: Float = 0.20
    var focalLengthMillimeters: Float = CameraRig.preview.lens.focalLengthMillimeters
    var radialDistortionK1: Float = CameraRig.preview.lens.radialDistortionK1

    let realtimeCore = RealtimeCore()
    let deviceRegistry = DeviceRegistry()
    let projectConfiguration = ProjectConfiguration.standard

    func startPreview() {
        realtimeCore.start()
        rendererStatus = .metalPreviewActive
    }

    func stopPreview() {
        realtimeCore.stop()
        rendererStatus = .previewStopped
    }

    func connectLocalCamera() {
        Task { [weak self] in
            guard let self else { return }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                self.rendererStatus = .cameraAccessNotGranted
                return
            }
            do {
                let source = try MacCameraVideoSource()
                if self.deviceRegistry.containsConnectedVideoDevice(named: source.descriptor.displayName) {
                    self.rendererStatus = .liveCameraPreviewActive
                    return
                }
                self.deviceRegistry.register(source.descriptor, role: .primaryCamera)
                source.onFrame = { [weak realtimeCore = self.realtimeCore] frame in
                    realtimeCore?.ingest(frame)
                }
                try self.realtimeCore.attach(source)
                self.deviceRegistry.updateState(for: source.descriptor.id, to: .connected)
                self.selectedSourceName = source.descriptor.displayName
                self.rendererStatus = .liveCameraPreviewActive
            } catch {
                self.rendererStatus = .error(error.localizedDescription)
            }
        }
    }

    func refreshMetrics() {
        let metrics = realtimeCore.metrics.read()
        frameRate = metrics.frameRate
        latencyMilliseconds = metrics.inputAgeMilliseconds
        gpuFrameMilliseconds = metrics.gpuFrameMilliseconds
        droppedFrameEstimate = metrics.droppedFrameEstimate
        inputColorMetadata = realtimeCore.latestVideoFrame.read()?.colorMetadata.summary ?? ""
    }
}
