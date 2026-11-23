import Foundation

final class RealtimeCore {
    private(set) var isRunning = false
    let latestVideoFrame = LatestVideoFrameStore()
    let metrics = RealtimeMetricsStore()
    private var videoSources: [any VideoSource] = []

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        videoSources.forEach { $0.stop() }
        latestVideoFrame.clear()
    }

    func attach(_ source: any VideoSource) throws {
        try source.start()
        videoSources.append(source)
    }

    func detach(_ id: UUID) {
        videoSources.filter { $0.descriptor.id == id }.forEach { $0.stop() }
        videoSources.removeAll { $0.descriptor.id == id }
    }

    func recordingPlugins(for sourceID: UUID) -> [TakeProvenance.Plugin] {
        let plugins = videoSources.first { $0.descriptor.id == sourceID }?.recordingPlugins ?? []
        return plugins.sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    func startRecording(_ recorder: CameraTakeRecorder, sourceID: UUID) -> Bool {
        let isLocalCamera = videoSources.contains { $0.descriptor.id == sourceID && $0 is MacCameraVideoSource }
        return latestVideoFrame.startRecording(recorder, sourceID: sourceID, tracksLocalInputLoss: isLocalCamera)
    }

    func ingest(_ frame: VideoFrame, from sourceID: UUID, sessionID: UUID? = nil) {
        latestVideoFrame.put(frame, sourceID: sourceID, sessionID: sessionID)
    }
}
