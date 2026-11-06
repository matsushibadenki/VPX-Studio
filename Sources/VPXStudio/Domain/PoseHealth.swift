import Foundation

/// Freshness is measured on the host when an aligned pose is accepted.
struct PoseHealth {
    var lastAcceptedNanoseconds: UInt64?
    var quality: StreamQuality = .lost

    func effectiveQuality(now: UInt64, clock: ClockFreshness) -> StreamQuality {
        guard clock == .current, let lastAcceptedNanoseconds,
              now >= lastAcceptedNanoseconds,
              now - lastAcceptedNanoseconds <= 500_000_000 else { return .lost }
        return quality
    }
}
