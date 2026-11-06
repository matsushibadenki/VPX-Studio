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
    private(set) var selectedSourceID: UUID?

    func selectSource(_ id: UUID) {
        guard let device = deviceRegistry.devices.first(where: { $0.id == id }),
              device.state == .connected, device.descriptor.capabilities.contains(.video) else { return }
        if isBenchmarkRunning, benchmarkSource?.descriptor.id != id {
            benchmarkSource?.stop()
            isBenchmarkRunning = false
            benchmarkResult?.status = .cancelled
            benchmarkResult?.completedAt = Date()
        }
        selectedSourceID = id
        selectedSourceName = device.descriptor.displayName
        selectedTrackingNodeID = captureNodeSources[id] == nil && benchmarkSource?.descriptor.id != id ? nil : id
        trackingQuality = .lost
        realtimeCore.latestVideoFrame.selectSource(id)
    }
    var trackingQuality: StreamQuality = .lost
    var rendererStatus: StudioStatus = .preparingMetalRenderer
    var frameRate = 0.0
    var inputHealth: VideoInputHealth = .missing
    var pipelineMeasurements = PipelineMeasurements()
    var poseCaptureAgeMilliseconds: Double?
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
    private var clockLastAccepted: [UUID: UInt64] = [:]
    private var poseHealth: [UUID: PoseHealth] = [:]
    private var selectedTrackingNodeID: UUID?
    private var diagnosticEvents = DiagnosticsEventHistory()
    private var benchmarkSource: BenchmarkVideoSource?
    private(set) var benchmarkResult: BenchmarkResult?
    private(set) var isBenchmarkRunning = false

    func startBenchmark() {
        guard !isBenchmarkRunning else { return }
        do {
            if let previous = benchmarkSource {
                realtimeCore.detach(previous.descriptor.id)
                deviceRegistry.remove(previous.descriptor.id)
                poseHealth.removeValue(forKey: previous.descriptor.id)
            }
            let source = try BenchmarkVideoSource()
            let id = source.descriptor.id
            source.onFrame = { [weak core = realtimeCore] frame in core?.ingest(frame, from: id) }
            source.onPose = { [weak self] pose, hostTime in
                Task { @MainActor [weak self] in
                    guard let self, self.isBenchmarkRunning, self.benchmarkSource?.descriptor.id == id else { return }
                    self.benchmarkResult?.deliveredFrames += 1
                    self.benchmarkResult?.replayedPoses += 1
                    self.benchmarkResult?.lastPose = pose
                    self.poseHealth[id] = PoseHealth(lastAcceptedNanoseconds: hostTime, quality: .nominal,
                                                    capturedHostNanoseconds: Double(hostTime))
                }
            }
            source.onComplete = { [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.isBenchmarkRunning == true, self?.benchmarkSource?.descriptor.id == id else { return }
                    self?.isBenchmarkRunning = false
                    self?.benchmarkResult?.completedAt = Date()
                    self?.benchmarkResult?.status = .completed
                    if let self { self.benchmarkResult?.measurements.append(self.realtimeCore.metrics.read()) }
                }
            }
            source.onFailure = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.isBenchmarkRunning == true, self?.benchmarkSource?.descriptor.id == id else { return }
                    self?.rendererStatus = .error(error.localizedDescription)
                    self?.isBenchmarkRunning = false
                    self?.benchmarkResult?.status = .failed
                }
            }
            benchmarkSource = source
            benchmarkResult = BenchmarkResult(fixture: source.fixture, startedAt: Date())
            benchmarkResult?.initialMeasurements = realtimeCore.metrics.read()
            isBenchmarkRunning = true
            deviceRegistry.register(source.descriptor, role: .secondaryCamera)
            deviceRegistry.updateState(for: id, to: .connected)
            selectSource(id)
            try realtimeCore.attach(source)
        } catch {
            isBenchmarkRunning = false
            rendererStatus = .error(error.localizedDescription)
        }
    }
    private var diagnosticsArchive: DiagnosticsArchive?
    private var archiveWriteInProgress = false
    private var archiveStarting = false
    private var archiveGeneration = UUID()
    private(set) var isArchivingDiagnostics = false
    var diagnosticsArchiveError: String?

    func startDiagnosticsArchive(to url: URL) async {
        guard diagnosticsArchive == nil, !archiveStarting else { return }
        archiveStarting = true
        let generation = archiveGeneration
        defer { archiveStarting = false }
        do {
            let archive = try DiagnosticsArchive(url: url)
            try await archive.append(diagnosticEvents.events)
            guard generation == archiveGeneration else {
                try await archive.close()
                return
            }
            diagnosticsArchive = archive
            isArchivingDiagnostics = true
        } catch { diagnosticsArchiveError = error.localizedDescription }
    }

    func stopDiagnosticsArchive() async {
        archiveGeneration = UUID()
        guard let archive = diagnosticsArchive else { return }
        diagnosticsArchive = nil
        isArchivingDiagnostics = false
        do {
            try await archive.append(diagnosticEvents.events)
            try await archive.close()
        } catch { diagnosticsArchiveError = error.localizedDescription }
    }

    private func flushDiagnosticsArchive() {
        guard let archive = diagnosticsArchive, !archiveWriteInProgress else { return }
        archiveWriteInProgress = true
        let events = diagnosticEvents.events
        Task {
            do { try await archive.append(events) }
            catch {
                diagnosticsArchiveError = error.localizedDescription
                if diagnosticsArchive === archive {
                    diagnosticsArchive = nil
                    isArchivingDiagnostics = false
                }
                try? await archive.close()
            }
            archiveWriteInProgress = false
        }
    }
    var diagnosticHistory: [DiagnosticsEventHistory.Event] { diagnosticEvents.events }
    var discardedDiagnosticEventCount: UInt64 { diagnosticEvents.discardedEventCount }
    private var poseJitterBuffers: [UUID: CapturePoseJitterBuffer] = [:]

    var activeCapturePairingCode: String? {
        activeCapturePairingCredential?.verificationCode
    }

    func startPreview() {
        realtimeCore.start()
        rendererStatus = .metalPreviewActive
    }

    func stopPreview() {
        if isBenchmarkRunning {
            isBenchmarkRunning = false
            benchmarkResult?.status = .cancelled
            benchmarkResult?.completedAt = Date()
        }
        Task { await stopDiagnosticsArchive() }
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
        if let selectedSourceID, captureNodeSources[selectedSourceID] != nil {
            realtimeCore.latestVideoFrame.selectSource(nil)
            self.selectedSourceID = nil
            selectedSourceName = ""
        }
        let now = DispatchTime.now().uptimeNanoseconds
        for id in captureNodeSources.keys {
            deviceRegistry.updateState(for: id, to: .disconnected)
            diagnosticEvents.observe(stream: .clock, nodeID: id, state: ClockFreshness.unmeasured.rawValue, hostTime: now)
            diagnosticEvents.observe(stream: .tracking, nodeID: id, state: StreamQuality.lost.rawValue, hostTime: now)
        }
        captureNodeHost?.stop()
        captureNodeHost = nil
        activeCapturePairingCredential = nil
        clockSyncTasks.values.forEach { $0.cancel() }
        clockSyncTasks.removeAll()
        clockSynchronizers.removeAll()
        clockStatistics.removeAll()
        clockLastAccepted.removeAll()
        poseHealth.removeAll()
        selectedTrackingNodeID = nil
        trackingQuality = .lost
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
                    if let existing = self.deviceRegistry.devices.first(where: {
                        $0.descriptor.displayName == source.descriptor.displayName && $0.state == .connected
                    }) { self.selectSource(existing.id) }
                    self.rendererStatus = .liveCameraPreviewActive
                    return
                }
                self.deviceRegistry.register(source.descriptor, role: .primaryCamera)
                let sourceID = source.descriptor.id
                source.onFrame = { [weak realtimeCore = self.realtimeCore] frame in
                    realtimeCore?.ingest(frame, from: sourceID)
                }
                try self.realtimeCore.attach(source)
                self.deviceRegistry.updateState(for: source.descriptor.id, to: .connected)
                if self.selectedSourceID == nil { self.selectSource(sourceID) }
                self.rendererStatus = .liveCameraPreviewActive
            } catch {
                self.rendererStatus = .error(error.localizedDescription)
            }
        }
    }

    func refreshMetrics() {
        realtimeCore.metrics.sampleMemory()
        let now = DispatchTime.now().uptimeNanoseconds
        if let id = selectedTrackingNodeID {
            trackingQuality = (poseHealth[id] ?? PoseHealth()).effectiveQuality(
                now: now, clock: benchmarkSource?.descriptor.id == id ? .current : .evaluate(lastAccepted: clockLastAccepted[id], now: now))
            poseCaptureAgeMilliseconds = poseHealth[id]?.captureAgeMilliseconds(now: now)
        } else {
            trackingQuality = .lost
            poseCaptureAgeMilliseconds = nil
        }
        let metrics = realtimeCore.metrics.read()
        pipelineMeasurements = metrics.pipeline
        if isBenchmarkRunning { benchmarkResult?.measurements.append(metrics) }
        inputHealth = metrics.inputHealth
        frameRate = metrics.frameRate
        latencyMilliseconds = metrics.inputAgeMilliseconds
        gpuFrameMilliseconds = metrics.gpuFrameMilliseconds
        droppedFrameEstimate = metrics.droppedFrameEstimate
        inputColorMetadata = realtimeCore.latestVideoFrame.read()?.colorMetadata.summary ?? ""
        diagnosticEvents.observe(stream: .videoInput, state: inputHealth.rawValue, hostTime: now)
        for id in captureNodeSources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let clock = ClockFreshness.evaluate(lastAccepted: clockLastAccepted[id], now: now)
            diagnosticEvents.observe(stream: .clock, nodeID: id, state: clock.rawValue, hostTime: now)
            let quality = (poseHealth[id] ?? PoseHealth()).effectiveQuality(now: now, clock: clock)
            diagnosticEvents.observe(stream: .tracking, nodeID: id, state: quality.rawValue, hostTime: now)
        }
        flushDiagnosticsArchive()
    }

    func diagnosticsReport() -> DiagnosticsReport {
        let now = DispatchTime.now().uptimeNanoseconds
        return DiagnosticsReport(
            schemaVersion: DiagnosticsReport.currentSchemaVersion, capturedAt: Date(), configuration: projectConfiguration,
            sourceName: selectedSourceName, metrics: realtimeCore.metrics.read(),
            clockOffsetMilliseconds: clockOffsetMilliseconds,
            networkRoundTripMilliseconds: networkRoundTripMilliseconds,
            networkJitterMilliseconds: networkJitterMilliseconds,
            clockDriftPartsPerMillion: clockDriftPartsPerMillion,
            nodes: captureNodeSources.keys.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
                let stats = clockStatistics[id]
                let last = clockLastAccepted[id]
                return .init(nodeID: id,
                    freshness: .evaluate(lastAccepted: last, now: now),
                    sampleAgeMilliseconds: last.flatMap { now >= $0 ? Double(now - $0) / 1_000_000 : nil },
                    offsetMilliseconds: stats.map { $0.nodeClockOffsetNanoseconds / 1_000_000 },
                    roundTripMilliseconds: stats.map { $0.roundTripNanoseconds / 1_000_000 },
                    jitterMilliseconds: stats.map { $0.jitterNanoseconds / 1_000_000 },
                    driftPartsPerMillion: stats?.driftPartsPerMillion,
                    poseQuality: (poseHealth[id] ?? PoseHealth()).effectiveQuality(
                        now: now, clock: .evaluate(lastAccepted: last, now: now)),
                    poseAgeMilliseconds: poseHealth[id]?.lastAcceptedNanoseconds.flatMap {
                        now >= $0 ? Double(now - $0) / 1_000_000 : nil
                    },
                    poseCaptureAgeMilliseconds: poseHealth[id]?.captureAgeMilliseconds(now: now))
            },
            events: diagnosticEvents.events,
            discardedEventCount: diagnosticEvents.discardedEventCount,
            benchmark: benchmarkResult
        )
    }

    private func attachCaptureNode(hello: CaptureNodeHello, channel: CaptureSecureChannel) {
        let source: CaptureNodeHEVCVideoSource
        if let existing = captureNodeSources[hello.nodeID] {
            source = existing
        } else {
            source = CaptureNodeHEVCVideoSource(hello: hello)
            source.onFrame = { [weak core = realtimeCore] frame in
                core?.ingest(frame, from: hello.nodeID)
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
        if selectedSourceID == nil { selectSource(hello.nodeID) }
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
        let now = DispatchTime.now().uptimeNanoseconds
        diagnosticEvents.observe(stream: .clock, nodeID: nodeID, state: ClockFreshness.unmeasured.rawValue, hostTime: now)
        diagnosticEvents.observe(stream: .tracking, nodeID: nodeID, state: StreamQuality.lost.rawValue, hostTime: now)
        captureNodeSources[nodeID]?.resetClockModel()
        clockLastAccepted.removeValue(forKey: nodeID)
        clockStatistics.removeValue(forKey: nodeID)
        clockSynchronizers.removeValue(forKey: nodeID)
        poseJitterBuffers.removeValue(forKey: nodeID)
        poseHealth.removeValue(forKey: nodeID)
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
        clockLastAccepted[nodeID] = exchange.hostReceiveNanoseconds
        clockOffsetMilliseconds = result.statistics.nodeClockOffsetNanoseconds / 1_000_000
        networkRoundTripMilliseconds = result.statistics.roundTripNanoseconds / 1_000_000
        networkJitterMilliseconds = result.statistics.jitterNanoseconds / 1_000_000
        clockDriftPartsPerMillion = result.statistics.driftPartsPerMillion
        clockStatistics[nodeID] = result.statistics
        captureNodeSources[nodeID]?.updateClockModel(result.statistics)
    }

    private func recordPose(_ pose: CapturePosePacket, from nodeID: UUID) {
        guard ClockFreshness.evaluate(lastAccepted: clockLastAccepted[nodeID], now: DispatchTime.now().uptimeNanoseconds) == .current,
              let statistics = clockStatistics[nodeID] else {
            poseJitterBuffers.removeValue(forKey: nodeID)
            poseHealth.removeValue(forKey: nodeID)
            if selectedTrackingNodeID == nodeID { trackingQuality = .lost }
            return
        }
        var buffer = poseJitterBuffers[nodeID] ?? CapturePoseJitterBuffer()
        buffer.enqueue(
            pose,
            nodeClockOffsetNanoseconds: statistics.nodeClockOffsetNanoseconds,
            clockDriftPartsPerMillion: statistics.driftPartsPerMillion,
            referenceHostNanoseconds: statistics.referenceHostNanoseconds
        )
        if let ready = buffer.dequeueLatestReady(hostNowNanoseconds: DispatchTime.now().uptimeNanoseconds) {
            let quality = Self.streamQuality(for: ready.quality)
            poseHealth[nodeID] = PoseHealth(lastAcceptedNanoseconds: DispatchTime.now().uptimeNanoseconds, quality: quality,
                capturedHostNanoseconds: HostClockMapping.hostTime(nodeNanoseconds: ready.captureTimeNanoseconds,
                    offset: statistics.nodeClockOffsetNanoseconds, driftPPM: statistics.driftPartsPerMillion,
                    referenceHost: statistics.referenceHostNanoseconds))
            if selectedTrackingNodeID == nodeID { trackingQuality = quality }
        }
        poseJitterBuffers[nodeID] = buffer
    }
}
