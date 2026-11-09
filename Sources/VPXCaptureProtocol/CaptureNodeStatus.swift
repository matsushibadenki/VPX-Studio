import Foundation

/// Low-rate device telemetry on the authenticated UDP channel. Temperature is
/// an OS pressure classification, never a fabricated temperature in degrees.
public struct CaptureNodeStatus: Codable, Sendable, Equatable {
    public enum BatteryState: String, Codable, Sendable { case unknown, unplugged, charging, full }
    public enum ThermalState: String, Codable, Sendable { case unknown, nominal, fair, serious, critical }
    public let sequence: UInt64
    public let captureTimeNanoseconds: UInt64
    public let batteryFraction: Double?
    public let batteryState: BatteryState
    public let thermalState: ThermalState
    public let isCapturing: Bool

    public init(sequence: UInt64, captureTimeNanoseconds: UInt64, batteryFraction: Double?,
                batteryState: BatteryState, thermalState: ThermalState, isCapturing: Bool) {
        self.sequence = sequence; self.captureTimeNanoseconds = captureTimeNanoseconds
        self.batteryFraction = batteryFraction; self.batteryState = batteryState
        self.thermalState = thermalState; self.isCapturing = isCapturing
    }

    public var isValid: Bool {
        batteryFraction.map { $0.isFinite && (0...1).contains($0) } ?? true
    }
}
