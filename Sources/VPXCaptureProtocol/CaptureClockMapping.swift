import Foundation

public enum CaptureClockMapping {
    /// Inverts node = host + offset + (host-reference) * drift exactly.
    public static func hostTime(nodeTime: UInt64, offset: Double, driftPPM: Double, reference: Double) -> Double? {
        let rate = driftPPM / 1_000_000
        guard offset.isFinite, rate.isFinite, reference.isFinite, abs(rate) < 0.1 else { return nil }
        let time = (Double(nodeTime) - offset + reference * rate) / (1 + rate)
        return time.isFinite && time >= 0 ? time : nil
    }
}

/// A bounded latest-depth slot. Depth is never applied without a current,
/// sufficiently certain clock model. The renderer/fusion phase consumes it later.
public struct CaptureDepthBuffer: Sendable {
    public private(set) var latest: CaptureDepthPacket?
    public private(set) var highConfidenceFraction: Double = 0
    private var hostTime: Double = 0
    public init() {}
    @discardableResult public mutating func receive(_ packet: CaptureDepthPacket, clock: CaptureClockStatistics,
                                                    hostNow: UInt64) -> Bool {
        guard CaptureSynchronizationPolicy().accepts(clock), (try? packet.validate()) != nil,
              let time = CaptureClockMapping.hostTime(nodeTime: packet.header.captureTimeNanoseconds,
                  offset: clock.nodeClockOffsetNanoseconds, driftPPM: clock.driftPartsPerMillion, reference: clock.referenceHostNanoseconds),
              Double(hostNow)-time >= -50_000_000, Double(hostNow)-time <= 500_000_000,
              latest.map({ packet.header.sequence > $0.header.sequence }) ?? true else { return false }
        latest=packet; hostTime=time
        highConfidenceFraction=Double(packet.confidence.filter { $0 == 2 }.count)/Double(packet.confidence.count)
        return true
    }
    public mutating func current(hostNow: UInt64) -> CaptureDepthPacket? {
        guard Double(hostNow)-hostTime <= 500_000_000 else { latest=nil; highConfidenceFraction=0; return nil }
        return latest
    }
}
