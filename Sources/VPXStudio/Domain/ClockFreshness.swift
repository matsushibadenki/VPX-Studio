import Foundation

enum ClockFreshness: String, Codable {
    case unmeasured, current, stale

    static func evaluate(lastAccepted: UInt64?, now: UInt64) -> Self {
        guard let lastAccepted else { return .unmeasured }
        guard now >= lastAccepted, now - lastAccepted <= 3_000_000_000 else { return .stale }
        return .current
    }
}
