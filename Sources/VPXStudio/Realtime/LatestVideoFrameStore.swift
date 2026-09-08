import Foundation

/// Thread-safe, bounded hand-off from a capture queue to the render thread.
///
/// Live compositing must prefer the newest frame. Retaining a queue of stale
/// frames increases perceived camera latency, so this mailbox keeps one value.
final class LatestVideoFrameStore {
    private let lock = NSLock()
    private var latest: VideoFrame?

    func put(_ frame: VideoFrame) {
        lock.lock()
        latest = frame
        lock.unlock()
    }

    func read() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }
}
