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

    func startRecording(_ recorder: CameraTakeRecorder, sourceID: UUID, tracksLocalInputLoss: Bool = false) -> Bool {
        lock.withLock {
            guard recording == nil, selectedSourceID == sourceID else { return false }
            if tracksLocalInputLoss, sessions[sourceID] == nil { recorder.startLocalInputLossMonitoring() }
            recording = (sourceID, sessions[sourceID], recorder)
            return true
        }
    }

    var compositeRecorder: CameraTakeRecorder? {
        lock.withLock {
            guard let recorder = recording?.recorder, recorder.composite else { return nil }
            return recorder
        }
    }

    var recordingHealth: CameraTakeRecorder.Health? {
        lock.withLock { recording?.recorder.health }
    }

    func observeLocalInputLoss(_ event: TakeProvenance.Recording.LocalInputLoss.Event, sourceID: UUID) {
        lock.withLock {
            guard selectedSourceID == sourceID, let recording, recording.sourceID == sourceID,
                  recording.sessionID == nil, sessions[sourceID] == nil else { return }
            recording.recorder.observeLocalInputLoss(event)
        }
    }

    func observeRecordingClock(sourceID: UUID, freshness: ClockFreshness, uncertaintyMilliseconds: Double?) {
        lock.withLock {
            guard let recording, recording.sourceID == sourceID, recording.sessionID != nil else { return }
            let status = sessions[sourceID] == nil ? .unmeasured : freshness
            recording.recorder.observeClock(status, uncertaintyMilliseconds: uncertaintyMilliseconds)
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
            let changed = suspended ? suspendedSources.insert(sourceID).inserted : suspendedSources.remove(sourceID) != nil
            if changed, recording?.sourceID == sourceID { recording?.recorder.resetInputSequenceBaseline() }
            if selectedSourceID == sourceID { latest = nil }
        }
    }

    /// Invalidates in-flight callbacks from a previous connection atomically
    /// with clearing the selected frame. Local sources use no session token.
    func beginSession(sourceID: UUID, sessionID: UUID) {
        lock.withLock {
            sessions[sourceID] = sessionID
            suspendedSources.remove(sourceID)
            if recording?.sourceID == sourceID { recording?.recorder.resetInputSequenceBaseline() }
            if selectedSourceID == sourceID { latest = nil }
        }
    }

    func endSession(sourceID: UUID, sessionID: UUID) {
        lock.withLock {
            guard sessions[sourceID] == sessionID else { return }
            sessions.removeValue(forKey: sourceID)
            suspendedSources.remove(sourceID)
            if recording?.sourceID == sourceID { recording?.recorder.resetInputSequenceBaseline() }
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
        if let recording, recording.sourceID == sourceID,
           recording.recorder.composite || recording.sessionID == sessionID {
            if sessionID != nil { recording.recorder.observeInputSequence(frame.identifier) }
            if !recording.recorder.composite { recording.recorder.submit(frame) }
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
