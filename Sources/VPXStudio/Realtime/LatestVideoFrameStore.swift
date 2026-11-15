import Foundation

/// Thread-safe, bounded hand-off from a capture queue to the render thread.
///
/// Live compositing must prefer the newest frame. Retaining a queue of stale
/// frames increases perceived camera latency, so this mailbox keeps one value.
final class LatestVideoFrameStore {
    private let lock = NSLock()
    private var latest: VideoFrame?
    private var selectedSourceID: UUID?
    private var sessions: [UUID: UUID] = [:]
    private var recording: (sourceID: UUID, sessionID: UUID?, recorder: CameraTakeRecorder)?

    func startRecording(_ recorder: CameraTakeRecorder, sourceID: UUID) -> Bool {
        lock.withLock {
            guard recording == nil, selectedSourceID == sourceID else { return false }
            recording = (sourceID, sessions[sourceID], recorder)
            return true
        }
    }

    var recordingFailed: Bool { lock.withLock { recording?.recorder.hasFailed == true } }

    func stopRecording() -> CameraTakeRecorder? {
        lock.withLock {
            let recorder = recording?.recorder
            recording = nil
            return recorder
        }
    }

    private var suspendedSources: Set<UUID> = []

    func setSuspended(_ suspended: Bool, sourceID: UUID, sessionID: UUID) {
        lock.withLock {
            guard sessions[sourceID] == sessionID else { return }
            if suspended { suspendedSources.insert(sourceID) } else { suspendedSources.remove(sourceID) }
            if selectedSourceID == sourceID { latest = nil }
        }
    }

    /// Invalidates in-flight callbacks from a previous connection atomically
    /// with clearing the selected frame. Local sources use no session token.
    func beginSession(sourceID: UUID, sessionID: UUID) {
        lock.withLock {
            sessions[sourceID] = sessionID
            suspendedSources.remove(sourceID)
            if selectedSourceID == sourceID { latest = nil }
        }
    }

    func endSession(sourceID: UUID, sessionID: UUID) {
        lock.withLock {
            guard sessions[sourceID] == sessionID else { return }
            sessions.removeValue(forKey: sourceID)
            suspendedSources.remove(sourceID)
            if selectedSourceID == sourceID { latest = nil }
        }
    }

    func selectSource(_ id: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        guard selectedSourceID != id else { return }
        selectedSourceID = id
        latest = nil
    }

    func put(_ frame: VideoFrame, sourceID: UUID, sessionID: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard sourceID == selectedSourceID else { return }
        guard sessions[sourceID] == sessionID else { return }
        guard !suspendedSources.contains(sourceID) else { return }
        latest = frame
        if let recording, recording.sourceID == sourceID, recording.sessionID == sessionID {
            recording.recorder.submit(frame)
        }
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
