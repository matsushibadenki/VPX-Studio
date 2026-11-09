import Foundation
import VPXCaptureProtocol

struct NodeStatusHealth {
    private(set) var packet: CaptureNodeStatus?
    private(set) var capturedHostNanoseconds: Double?

    mutating func accept(_ packet: CaptureNodeStatus, capturedHost: Double, now: UInt64, clock: ClockFreshness) {
        let age = Double(now) - capturedHost
        guard clock == .current, packet.isValid, capturedHost.isFinite,
              capturedHost >= 0, age >= -50_000_000, age <= 3_000_000_000,
              self.packet.map({ packet.sequence > $0.sequence && packet.captureTimeNanoseconds > $0.captureTimeNanoseconds }) ?? true else { return }
        self.packet = packet; capturedHostNanoseconds = capturedHost
    }

    func current(now: UInt64, clock: ClockFreshness) -> CaptureNodeStatus? {
        guard clock == .current, let capturedHostNanoseconds,
              Double(now) - capturedHostNanoseconds >= -50_000_000,
              Double(now) - capturedHostNanoseconds <= 3_000_000_000 else { return nil }
        return packet
    }
}

struct NodeVideoMonitoring: Codable, Sendable {
    var captured: Double?
    var decoded: Double?
    var decodeMilliseconds: Double?
    func captureAgeMilliseconds(now: Double) -> Double? {
        guard let captured, now >= captured else { return nil }
        return (now - captured) * 1_000
    }
}

struct NodeMonitoringSnapshot: Codable, Identifiable {
    let id: UUID
    let name: String
    let connected: Bool
    let selected: Bool
    let clock: ClockFreshness
    let frameAgeMilliseconds: Double?
    let decodeMilliseconds: Double?
    let poseQuality: StreamQuality
    let poseAgeMilliseconds: Double?
    let roundTripMilliseconds: Double?
    let jitterMilliseconds: Double?
    let trackingReason: String?
    let status: CaptureNodeStatus?
    var mediaControl: NodeMediaControl?
}
