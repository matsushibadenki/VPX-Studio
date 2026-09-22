import Foundation

/// Bounded, timestamp-ordered HEVC buffer. Node timestamps are translated into
/// the Host clock domain before ordering, using the active clock offset from
/// `CaptureClockSynchronizer`.
public struct CaptureVideoJitterBuffer: Sendable {
    private struct Entry: Sendable {
        let frame: CaptureEncodedVideoFrame
        let hostPresentationNanoseconds: Double
    }

    public let targetDelayNanoseconds: Double
    public let maximumFrameCount: Int
    public private(set) var droppedFrameCount: UInt64 = 0
    private var entries: [Entry] = []

    public init(
        targetDelayNanoseconds: Double = 50_000_000,
        maximumFrameCount: Int = 12
    ) {
        self.targetDelayNanoseconds = max(0, targetDelayNanoseconds)
        self.maximumFrameCount = max(1, maximumFrameCount)
    }

    /// Inserts one frame. Duplicate sequences and oldest overflow entries are
    /// dropped deterministically, preserving the newest realtime content.
    public mutating func enqueue(
        _ frame: CaptureEncodedVideoFrame,
        nodeClockOffsetNanoseconds: Double,
        clockDriftPartsPerMillion: Double = 0,
        referenceHostNanoseconds: Double = 0
    ) {
        guard !entries.contains(where: { $0.frame.header.sequence == frame.header.sequence }) else {
            droppedFrameCount &+= 1
            return
        }
        let elapsed = Double(frame.header.captureTimeNanoseconds) - referenceHostNanoseconds
        let effectiveOffset = nodeClockOffsetNanoseconds
            + elapsed * clockDriftPartsPerMillion / 1_000_000
        let presentationTime = Double(frame.header.captureTimeNanoseconds) - effectiveOffset
        let entry = Entry(frame: frame, hostPresentationNanoseconds: presentationTime)
        let insertionIndex = entries.firstIndex {
            $0.hostPresentationNanoseconds > presentationTime
        } ?? entries.endIndex
        entries.insert(entry, at: insertionIndex)

        while entries.count > maximumFrameCount {
            entries.removeFirst()
            droppedFrameCount &+= 1
        }
    }

    /// Returns frames old enough to present at the supplied Host monotonic time.
    public mutating func dequeueReady(hostNowNanoseconds: UInt64) -> [CaptureEncodedVideoFrame] {
        let deadline = Double(hostNowNanoseconds) - targetDelayNanoseconds
        var ready: [CaptureEncodedVideoFrame] = []
        while let first = entries.first, first.hostPresentationNanoseconds <= deadline {
            ready.append(first.frame)
            entries.removeFirst()
        }
        return ready
    }

    public var queuedFrameCount: Int { entries.count }
}

/// Timestamp-ordered buffer for tracking data. It provides a single latest
/// Pose suitable for the current render tick while discarding stale arrivals.
public struct CapturePoseJitterBuffer: Sendable {
    private struct Entry: Sendable {
        let pose: CapturePosePacket
        let hostPresentationNanoseconds: Double
    }

    public let targetDelayNanoseconds: Double
    public let maximumPacketCount: Int
    public private(set) var droppedPacketCount: UInt64 = 0
    private var entries: [Entry] = []

    public init(targetDelayNanoseconds: Double = 20_000_000, maximumPacketCount: Int = 48) {
        self.targetDelayNanoseconds = max(0, targetDelayNanoseconds)
        self.maximumPacketCount = max(1, maximumPacketCount)
    }

    public mutating func enqueue(
        _ pose: CapturePosePacket,
        nodeClockOffsetNanoseconds: Double,
        clockDriftPartsPerMillion: Double = 0,
        referenceHostNanoseconds: Double = 0
    ) {
        guard !entries.contains(where: { $0.pose.sequence == pose.sequence }) else {
            droppedPacketCount &+= 1
            return
        }
        let elapsed = Double(pose.captureTimeNanoseconds) - referenceHostNanoseconds
        let effectiveOffset = nodeClockOffsetNanoseconds
            + elapsed * clockDriftPartsPerMillion / 1_000_000
        let presentationTime = Double(pose.captureTimeNanoseconds) - effectiveOffset
        let entry = Entry(pose: pose, hostPresentationNanoseconds: presentationTime)
        let index = entries.firstIndex { $0.hostPresentationNanoseconds > presentationTime } ?? entries.endIndex
        entries.insert(entry, at: index)
        while entries.count > maximumPacketCount {
            entries.removeFirst()
            droppedPacketCount &+= 1
        }
    }

    /// Delivers the newest ready pose and discards older ready poses.
    public mutating func dequeueLatestReady(hostNowNanoseconds: UInt64) -> CapturePosePacket? {
        let deadline = Double(hostNowNanoseconds) - targetDelayNanoseconds
        var latest: CapturePosePacket?
        while let first = entries.first, first.hostPresentationNanoseconds <= deadline {
            latest = first.pose
            entries.removeFirst()
        }
        return latest
    }

    public var queuedPacketCount: Int { entries.count }
}
