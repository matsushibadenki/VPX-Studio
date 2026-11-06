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

    func ingest(_ frame: VideoFrame, from sourceID: UUID) {
        latestVideoFrame.put(frame, sourceID: sourceID)
    }
}
