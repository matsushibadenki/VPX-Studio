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

    func ingest(_ frame: VideoFrame) {
        latestVideoFrame.put(frame)
    }
}
