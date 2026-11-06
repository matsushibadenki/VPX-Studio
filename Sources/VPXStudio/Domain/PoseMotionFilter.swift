import Foundation
import simd
import VPXCaptureProtocol

/// Conservative motion gate, independent for each Node. Rejected measurements
/// never become a baseline and never refresh the tracking freshness timer.
struct PoseMotionFilter {
    enum Rejection: String, Codable { case malformed, unavailable, reordered, motion, reacquiring }
    struct Measurement {
        let time: UInt64
        let sequence: UInt64
        let revision: UInt64
        let position: SIMD3<Float>
        let rotation: simd_quatf
        var transform: simd_float4x4 {
            var matrix = simd_float4x4(rotation)
            matrix.columns.3 = SIMD4(position, 1)
            return matrix
        }
    }
    var maximumSpeedMetersPerSecond: Float = 20
    var maximumAngularSpeedRadiansPerSecond: Float = 20
    var maximumGapSeconds: Double = 0.5
    private var baseline: Measurement?
    private var candidate: Measurement?
    private var candidateCount = 0
    private(set) var acceptedCount: UInt64 = 0
    private(set) var rejectedCount: UInt64 = 0
    private(set) var lastRejection: Rejection?

    mutating func interruptReacquisition() {
        candidate = nil; candidateCount = 0
    }

    mutating func accept(_ packet: CapturePosePacket) -> Measurement? {
        guard packet.translationMeters.count == 3, packet.rotationQuaternion.count == 4,
              (packet.translationMeters + packet.rotationQuaternion).allSatisfy(\.isFinite) else {
            return reject(.malformed)
        }
        let p = packet.translationMeters, q = packet.rotationQuaternion
        let vector = SIMD4(q[0],q[1],q[2],q[3])
        let length = simd_length(vector)
        guard length.isFinite, abs(length-1) <= 0.05,
              p.allSatisfy({ abs($0) <= 100_000 }) else { return reject(.malformed) }
        guard packet.quality != .lost else { return reject(.unavailable) }
        let current = Measurement(time: packet.captureTimeNanoseconds, sequence: packet.sequence,
            revision: packet.referenceSpaceRevision, position: SIMD3(p[0],p[1],p[2]),
            rotation: simd_quatf(vector: vector/length))
        if let previous = baseline {
            // The caller must separately invalidate stage calibration on revision changes.
            if previous.revision != current.revision {
                baseline = nil; candidate = nil; candidateCount = 0
            } else {
                guard current.time > previous.time, current.sequence > previous.sequence else { return reject(.reordered) }
                let elapsed = Double(current.time-previous.time)/1_000_000_000
                if elapsed > maximumGapSeconds {
                    guard plausible(current, after: previous) else { return reject(.motion) }
                    if let candidate, candidate.revision == current.revision,
                       current.sequence > candidate.sequence, current.time > candidate.time,
                       Double(current.time-candidate.time)/1_000_000_000 <= maximumGapSeconds,
                       plausible(current, after: candidate) {
                        candidateCount += 1
                    } else { candidateCount = 1 }
                    candidate = current
                    guard candidateCount >= 3 else { return reject(.reacquiring) }
                } else {
                    guard plausible(current, after: previous) else { return reject(.motion) }
                }
            }
        }
        baseline = current; candidate = nil; candidateCount = 0
        acceptedCount &+= 1; lastRejection = nil
        return current
    }

    private func plausible(_ current: Measurement, after previous: Measurement) -> Bool {
        let seconds = Float(Double(current.time-previous.time)/1_000_000_000)
        guard seconds > 0 else { return false }
        let distance = simd_distance(current.position, previous.position)
        // q and -q describe the same orientation. Clamp roundoff before acos.
        let dot = min(1, max(0, abs(simd_dot(current.rotation.vector, previous.rotation.vector))))
        let angle = 2*acos(dot)
        return distance <= maximumSpeedMetersPerSecond*seconds + 0.005 &&
            angle <= maximumAngularSpeedRadiansPerSecond*seconds + 0.005
    }

    private mutating func reject(_ reason: Rejection) -> Measurement? {
        rejectedCount &+= 1; lastRejection = reason
        // A malformed or out-of-order sample breaks consecutive reacquisition.
        if reason != .reacquiring { candidate = nil; candidateCount = 0 }
        return nil
    }
}

extension PoseMotionFilter.Rejection {
    var localizationKey: LocalizationKey {
        switch self {
        case .malformed: .poseMalformed
        case .unavailable: .poseUnavailable
        case .reordered: .poseReordered
        case .motion: .poseMotionRejected
        case .reacquiring: .poseReacquiring
        }
    }
}
