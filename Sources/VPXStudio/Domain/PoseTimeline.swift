import Foundation
import simd

/// Host-clock, bounded history. Render sampling targets the video capture time,
/// never the current drawable time. All extrapolation is explicitly bounded.
struct PoseTimeline: Sendable {
    struct Sample: Sendable {
        let time: Double
        let position: SIMD3<Float>
        let rotation: simd_quatf
        let nominal: Bool
    }
    enum Mode: String, Codable, Sendable { case measured, interpolated, predicted }
    struct Resolved: Sendable {
        let transform: simd_float4x4
        let mode: Mode
        let horizonMilliseconds: Double
    }
    private(set) var samples: [Sample] = []
    private(set) var predictionErrorMeters: Float?
    private(set) var predictionErrorRadians: Float?
    private(set) var predictionErrorHorizonMilliseconds: Double?

    mutating func append(time: Double, transform: simd_float4x4, nominal: Bool) {
        guard time.isFinite, time >= 0, (try? StageRegistration.validateRigid(transform)) != nil else { return }
        if let last = samples.last, time <= last.time || time-last.time > 0.1 {
            // Offset changes and gaps must not interpolate across discontinuities.
            samples.removeAll()
        }
        predictionErrorMeters = nil; predictionErrorRadians = nil; predictionErrorHorizonMilliseconds = nil
        if nominal, let predicted = resolve(at: time, now: time, maximumAge: 0.5), predicted.mode == .predicted {
            let delta = predicted.transform.columns.3 - transform.columns.3
            predictionErrorMeters = simd_length(SIMD3(delta.x,delta.y,delta.z))
            let a = simd_quatf(predicted.transform), b = simd_quatf(transform)
            predictionErrorRadians = 2*acos(min(1, abs(simd_dot(a.vector,b.vector))))
            predictionErrorHorizonMilliseconds = predicted.horizonMilliseconds
        }
        samples.append(Sample(time: time, position: SIMD3(transform[3].x,transform[3].y,transform[3].z),
            rotation: simd_normalize(simd_quatf(transform)), nominal: nominal))
        if samples.count > 128 { samples.removeFirst(samples.count-128) }
    }

    func resolve(at target: Double, now: Double, maximumAge: Double) -> Resolved? {
        guard target.isFinite, now.isFinite, maximumAge.isFinite, maximumAge > 0,
              let first = samples.first, let last = samples.last,
              now >= target, now-target <= maximumAge, now >= last.time, now-last.time <= maximumAge,
              target >= first.time else { return nil }
        if let exact = samples.first(where: { abs($0.time-target) < 0.000_001 }) {
            return result(position: exact.position, rotation: exact.rotation, mode: .measured, horizon: 0)
        }
        for i in 1..<samples.count where target < samples[i].time {
            let a = samples[i-1], b = samples[i]
            let gap = b.time-a.time
            guard gap > 0, gap <= 0.1 else { return nil }
            let fraction = Float((target-a.time)/gap)
            return result(position: a.position+(b.position-a.position)*fraction,
                rotation: simd_slerp(a.rotation,b.rotation,fraction), mode: .interpolated, horizon: 0)
        }
        guard samples.count >= 2 else { return nil }
        let previous = samples[samples.count-2]
        let horizon = target-last.time, interval = last.time-previous.time
        guard last.nominal, previous.nominal, horizon > 0, horizon <= 0.03 + 1e-9, interval >= 0.001, interval <= 0.1 else { return nil }
        let velocity = (last.position-previous.position)/Float(interval)
        var delta = previous.rotation.inverse * last.rotation
        if delta.real < 0 { delta = simd_quatf(vector: -delta.vector) }
        let angle = 2*acos(min(1,max(-1,delta.real)))
        let angularSpeed = angle/Float(interval)
        let displacement = velocity*Float(horizon)
        guard simd_length(velocity) <= 20, angularSpeed <= 20,
              simd_length(displacement) <= 0.2, angularSpeed*Float(horizon) <= 0.2 else { return nil }
        let rotation = angle > 0.000_001
            ? last.rotation * simd_quatf(angle: angularSpeed*Float(horizon),axis: delta.axis) : last.rotation
        return result(position: last.position+displacement,rotation: rotation,mode: .predicted,horizon: horizon*1000)
    }

    private func result(position: SIMD3<Float>, rotation: simd_quatf, mode: Mode, horizon: Double) -> Resolved {
        var transform = simd_float4x4(rotation)
        transform.columns.3 = SIMD4(position,1)
        return Resolved(transform: transform,mode: mode,horizonMilliseconds: horizon)
    }
}

struct PoseCameraAlignment: Sendable {
    let sourceID: UUID
    let history: PoseTimeline
    let stageFromNodeWorld: simd_float4x4
    let maximumAge: Double

    func resolve(videoCaptureTime: Double?, now: Double) -> PoseTimeline.Resolved? {
        guard let videoCaptureTime, let pose = history.resolve(at: videoCaptureTime,now: now,maximumAge: maximumAge) else { return nil }
        return .init(transform: stageFromNodeWorld*pose.transform,mode: pose.mode,horizonMilliseconds: pose.horizonMilliseconds)
    }
}

struct PoseAlignmentTelemetry: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case unavailable, measured, interpolated, predicted }
    let mode: Mode
    let horizonMilliseconds: Double?
    let predictionErrorMeters: Float?
    let predictionErrorRadians: Float?
    let predictionErrorHorizonMilliseconds: Double?
}

extension PoseAlignmentTelemetry.Mode {
    var localizationKey: LocalizationKey {
        switch self {
        case .unavailable: .poseAlignmentUnavailable
        case .measured: .poseMeasured
        case .interpolated: .poseInterpolated
        case .predicted: .posePredicted
        }
    }
}
