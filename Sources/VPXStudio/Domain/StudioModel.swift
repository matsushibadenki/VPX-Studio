@preconcurrency import AVFoundation
import Observation
import VPXCaptureProtocol

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
    var clockOffsetMilliseconds = 0.0
    var networkRoundTripMilliseconds = 0.0
    var networkJitterMilliseconds = 0.0
    var clockDriftPartsPerMillion = 0.0
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
    private(set) var activeCapturePairingCredential: CapturePairingCredential?
    private var captureNodeHost: CaptureNodeBonjourHost?
    private var captureNodeSources: [UUID: CaptureNodeHEVCVideoSource] = [:]
    private var clockSyncTasks: [UUID: Task<Void, Never>] = [:]
    private var clockSynchronizers: [UUID: CaptureClockSynchronizer] = [:]
    private var clockStatistics: [UUID: CaptureClockStatistics] = [:]
    private var poseJitterBuffers: [UUID: CapturePoseJitterBuffer] = [:]

    var activeCapturePairingCode: String? {
        activeCapturePairingCredential?.verificationCode
    }

    func startPreview() {
        realtimeCore.start()
        rendererStatus = .metalPreviewActive
    }

    func stopPreview() {
        realtimeCore.stop()
        rendererStatus = .previewStopped
    }

    /// Starts a single active pairing session and advertises the Host via Bonjour.
    /// The credential is intended for QR transfer; `activeCapturePairingCode` is
    /// the short value the operator compares on both devices before confirming.
    func startCaptureNodeHost() {
        guard captureNodeHost == nil else { return }
        do {
            let credential = try CapturePairingCredential.create()
            let host = CaptureNodeBonjourHost(credential: credential)
            host.onHello = { [weak self] hello, channel in
                Task { @MainActor [weak self] in
                    self?.attachCaptureNode(hello: hello, channel: channel)
                }
            }
            host.onFailure = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.rendererStatus = .error(error.localizedDescription)
                }
            }
            try host.start()
            activeCapturePairingCredential = credential
            captureNodeHost = host
        } catch {
            rendererStatus = .error(error.localizedDescription)
        }
    }

    func stopCaptureNodeHost() {
        captureNodeHost?.stop()
        captureNodeHost = nil
        activeCapturePairingCredential = nil
        clockSyncTasks.values.forEach { $0.cancel() }
        clockSyncTasks.removeAll()
        clockSynchronizers.removeAll()
        clockStatistics.removeAll()
        poseJitterBuffers.removeAll()
        captureNodeSources.values.forEach { $0.stop() }
        captureNodeSources.removeAll()
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

    private func attachCaptureNode(hello: CaptureNodeHello, channel: CaptureSecureChannel) {
        let source: CaptureNodeHEVCVideoSource
        if let existing = captureNodeSources[hello.nodeID] {
            source = existing
        } else {
            source = CaptureNodeHEVCVideoSource(hello: hello)
            source.onFrame = { [weak core = realtimeCore] frame in
                core?.ingest(frame)
            }
            source.onFailure = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.deviceRegistry.updateState(for: hello.nodeID, to: .failed(error.localizedDescription))
                }
            }
            do {
                try realtimeCore.attach(source)
                deviceRegistry.register(source.descriptor, role: .primaryCamera)
                captureNodeSources[hello.nodeID] = source
            } catch {
                deviceRegistry.register(source.descriptor, role: .primaryCamera)
                deviceRegistry.updateState(for: hello.nodeID, to: .failed(error.localizedDescription))
                return
            }
        }

        channel.onVideoFrame = { [weak source] frame in
            do {
                try source?.receive(frame)
            } catch {
                source?.onFailure?(error)
            }
        }
        channel.onPosePacket = { [weak self] pose in
            Task { @MainActor [weak self] in
                self?.recordPose(pose, from: hello.nodeID)
            }
        }
        channel.onClockReply = { [weak self] reply in
            let hostReceiveNanoseconds = DispatchTime.now().uptimeNanoseconds
            let exchange = CaptureClockExchange(
                hostSendNanoseconds: reply.hostSendNanoseconds,
                nodeReceiveNanoseconds: reply.nodeReceiveNanoseconds,
                nodeSendNanoseconds: reply.nodeSendNanoseconds,
                hostReceiveNanoseconds: hostReceiveNanoseconds
            )
            Task { @MainActor [weak self] in
                self?.recordClockExchange(exchange, for: hello.nodeID)
            }
        }
        startClockSync(for: hello.nodeID, channel: channel)
        deviceRegistry.updateState(for: hello.nodeID, to: .connected)
        selectedSourceName = hello.displayName
    }

    private static func streamQuality(for quality: CaptureTrackingQuality) -> StreamQuality {
        switch quality {
        case .nominal: .nominal
        case .degraded, .limited: .degraded
        case .lost: .lost
        }
    }

    private func startClockSync(for nodeID: UUID, channel: CaptureSecureChannel) {
        clockSyncTasks[nodeID]?.cancel()
        clockSyncTasks[nodeID] = Task { [weak channel] in
            while !Task.isCancelled {
                let probe = CaptureClockProbe(
                    hostSendNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
                try? channel?.sendClockProbe(probe)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func recordClockExchange(_ exchange: CaptureClockExchange, for nodeID: UUID) {
        var synchronizer = clockSynchronizers[nodeID] ?? CaptureClockSynchronizer()
        guard let result = try? synchronizer.record(exchange) else { return }
        clockSynchronizers[nodeID] = synchronizer
        guard result.wasAccepted else { return }
        clockOffsetMilliseconds = result.statistics.nodeClockOffsetNanoseconds / 1_000_000
        networkRoundTripMilliseconds = result.statistics.roundTripNanoseconds / 1_000_000
        networkJitterMilliseconds = result.statistics.jitterNanoseconds / 1_000_000
        clockDriftPartsPerMillion = result.statistics.driftPartsPerMillion
        clockStatistics[nodeID] = result.statistics
        captureNodeSources[nodeID]?.updateClockModel(result.statistics)
    }

    private func recordPose(_ pose: CapturePosePacket, from nodeID: UUID) {
        var buffer = poseJitterBuffers[nodeID] ?? CapturePoseJitterBuffer()
        let statistics = clockStatistics[nodeID]
        buffer.enqueue(
            pose,
            nodeClockOffsetNanoseconds: statistics?.nodeClockOffsetNanoseconds ?? clockOffsetMilliseconds * 1_000_000,
            clockDriftPartsPerMillion: statistics?.driftPartsPerMillion ?? clockDriftPartsPerMillion,
            referenceHostNanoseconds: statistics?.referenceHostNanoseconds ?? 0
        )
        if let ready = buffer.dequeueLatestReady(hostNowNanoseconds: DispatchTime.now().uptimeNanoseconds) {
            trackingQuality = Self.streamQuality(for: ready.quality)
        }
        poseJitterBuffers[nodeID] = buffer
    }
}
