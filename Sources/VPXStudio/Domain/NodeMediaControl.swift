import Foundation
import VPXCaptureProtocol

struct NodeMediaControl: Codable {
    private(set) var suspended: Bool? = false
    private(set) var pending: CaptureNodeControlCommand?
    private(set) var sentAt: UInt64?
    private(set) var failed = false

    mutating func request(suspend: Bool, now: UInt64) -> CaptureNodeControlCommand? {
        guard pending == nil else { return nil }
        let command = CaptureNodeControlCommand(action: suspend ? .suspendMedia : .resumeMedia)
        pending = command; sentAt = now; failed = false
        return command
    }
    @discardableResult
    mutating func complete(_ result: CaptureMediaControlResult, now: UInt64? = nil) -> Bool {
        if let now { expire(now: now) }
        guard let pending, pending.commandID == result.commandID,
              (pending.action == .suspendMedia) == result.suspended else { return false }
        suspended = result.suspended; self.pending = nil; sentAt = nil; failed = false
        return true
    }
    mutating func expire(now: UInt64) {
        guard let sentAt, now < sentAt || now - sentAt >= 3_000_000_000 else { return }
        fail()
    }
    mutating func fail() { suspended = nil; pending = nil; sentAt = nil; failed = true }
}
