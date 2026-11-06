import Foundation

/// Thread-safe, bounded hand-off from a capture queue to the render thread.
///
/// Live compositing must prefer the newest frame. Retaining a queue of stale
/// frames increases perceived camera latency, so this mailbox keeps one value.
final class LatestVideoFrameStore {
    private let lock = NSLock()
    private var latest: VideoFrame?
    private var selectedSourceID: UUID?

    func selectSource(_ id: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        guard selectedSourceID != id else { return }
        selectedSourceID = id
        latest = nil
    }

    func put(_ frame: VideoFrame, sourceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard sourceID == selectedSourceID else { return }
        latest = frame
    }

    func read() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func readSnapshot() -> (sourceID: UUID?, frame: VideoFrame?) {
        lock.lock()
        defer { lock.unlock() }
        return (selectedSourceID, latest)
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }
}
