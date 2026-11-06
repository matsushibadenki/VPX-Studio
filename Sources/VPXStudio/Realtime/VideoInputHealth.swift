import Foundation

enum VideoInputHealth: Sendable, Equatable {
    case missing, active, stale

    /// Uses host receive time only; remote capture clocks must be aligned first.
    static func evaluate(ageSeconds: Double?, qualityLost: Bool = false) -> Self {
        guard let ageSeconds else { return .missing }
        guard ageSeconds.isFinite, ageSeconds >= 0,
              ageSeconds <= 0.5, !qualityLost else { return .stale }
        return .active
    }
}
