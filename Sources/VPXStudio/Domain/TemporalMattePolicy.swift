import Foundation

/// The GPU stores one previous image/matte pair. The CPU owns only identity
/// and timing; no pixel data crosses into SwiftUI.
struct TemporalMattePolicy {
    enum Mode: String, Codable, Sendable { case disabled, reset, blend, reuse }
    struct Key: Equatable {
        let sourceID: UUID
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let normalization: [Float]
        var quality: StreamQuality = .nominal
    }
    private var previousKey: Key?
    private var previousSequence: UInt64?
    private var previousCaptureTime: Double?

    mutating func reset() {
        previousKey = nil; previousSequence = nil; previousCaptureTime = nil
    }

    mutating func next(key: Key?, sequence: UInt64?, captureTime: Double?, enabled: Bool) -> Mode {
        guard enabled, let key, let sequence, let time = captureTime, time.isFinite, time >= 0,
              key.width > 0, key.height > 0, key.normalization.allSatisfy(\.isFinite) else {
            reset(); return .disabled
        }
        defer { previousKey = key; previousSequence = sequence; previousCaptureTime = time }
        guard previousKey == key, let lastSequence = previousSequence, let lastTime = previousCaptureTime else { return .reset }
        if sequence == lastSequence && time == lastTime { return .reuse }
        guard sequence > lastSequence, time > lastTime, time-lastTime <= 0.1 else { return .reset }
        return .blend
    }
}

extension TemporalMattePolicy.Mode {
    var localizationKey: LocalizationKey {
        switch self {
        case .disabled: .temporalMatteDisabled
        case .reset: .temporalMatteReset
        case .blend: .temporalMatteBlend
        case .reuse: .temporalMatteReuse
        }
    }
}
