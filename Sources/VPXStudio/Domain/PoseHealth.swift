import Foundation

/// Freshness is measured on the host when an aligned pose is accepted.
struct PoseHealth {
    var lastAcceptedNanoseconds: UInt64?
    var quality: StreamQuality = .lost
    var capturedHostNanoseconds: Double?

    func captureAgeMilliseconds(now: UInt64) -> Double? {
        FrameTelemetry.milliseconds(from: capturedHostNanoseconds.map { $0 / 1_000_000_000 },
                                    to: Double(now) / 1_000_000_000)
    }

    func effectiveQuality(now: UInt64, clock: ClockFreshness) -> StreamQuality {
        guard clock == .current, let lastAcceptedNanoseconds,
              now >= lastAcceptedNanoseconds,
              now - lastAcceptedNanoseconds <= 500_000_000 else { return .lost }
        if capturedHostNanoseconds != nil {
            guard let age = captureAgeMilliseconds(now: now), age <= 500 else { return .lost }
        }
        return quality
    }
}
