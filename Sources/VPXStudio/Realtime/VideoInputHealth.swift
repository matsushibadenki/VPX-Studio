import Foundation

enum VideoInputHealth: String, Codable, Sendable, Equatable {
    case missing, active, stale

    /// Uses host receive time only; remote capture clocks must be aligned first.
    static func evaluate(ageSeconds: Double?, qualityLost: Bool = false, timeoutSeconds: Double = 0.5,
                         captureAgeSeconds: Double? = nil) -> Self {
        guard let ageSeconds else { return .missing }
        guard ageSeconds.isFinite, ageSeconds >= 0,
              ageSeconds <= timeoutSeconds, !qualityLost else { return .stale }
        if let captureAgeSeconds {
            guard captureAgeSeconds.isFinite, captureAgeSeconds >= 0, captureAgeSeconds <= timeoutSeconds else { return .stale }
        }
        return .active
    }
}
