import Foundation

enum HostClockMapping {
    /// node = host + offset + (host - referenceHost) * drift.
    static func hostTime(nodeNanoseconds: UInt64, offset: Double, driftPPM: Double, referenceHost: Double) -> Double? {
        let drift = driftPPM / 1_000_000
        guard offset.isFinite, drift.isFinite, referenceHost.isFinite, 1 + drift > 0 else { return nil }
        let result = (Double(nodeNanoseconds) - offset + referenceHost * drift) / (1 + drift)
        return result.isFinite && result >= 0 ? result : nil
    }
}
