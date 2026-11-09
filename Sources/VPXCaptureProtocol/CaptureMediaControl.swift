import Foundation

public struct CaptureMediaControlResult: Codable, Sendable, Equatable {
    public let commandID: UUID
    public let suspended: Bool
    public init(commandID: UUID, suspended: Bool) {
        self.commandID = commandID; self.suspended = suspended
    }
}

/// Serializes media submission with the pause acknowledgement. Pose, clock and
/// diagnostics bypass this gate. Capturing/encoding remain active while paused.
public final class CaptureMediaTransmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var suspended = false
    public init() {}
    public func reset() { lock.withLock { suspended = false } }
    public func submit(_ send: () throws -> Void) rethrows {
        try lock.withLock { if !suspended { try send() } }
    }
    @discardableResult
    public func apply(_ command: CaptureNodeControlCommand,
                      acknowledge: (CaptureMediaControlResult) throws -> Void) rethrows -> Bool {
        try lock.withLock {
            switch command.action {
            case .suspendMedia: suspended = true
            case .resumeMedia: suspended = false
            default: return false
            }
            try acknowledge(CaptureMediaControlResult(commandID: command.commandID, suspended: suspended))
            return true
        }
    }
}
