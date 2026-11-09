import Foundation
import VPXCaptureProtocol

/// Reservations for active authenticated streams, not a measured GPU/Wi-Fi budget.
/// Accessed only on the Host networking queue.
struct NodeAdmissionPolicy {
    struct Limits: Codable, Equatable, Sendable {
        var nodes: Int
        var videoStreams: Int
        static let standard = Limits(nodes: 4, videoStreams: 4)
    }
    enum Rejection: String, Codable, Sendable {
        case nodeLimit, videoLimit, identityChanged, capabilitiesChanged
    }
    enum Decision: Equatable {
        case accepted, duplicate, rejected(Rejection)
    }
    private struct Reservation {
        let nodeID: UUID
        let connectionID: UUID
        let capabilities: Set<CaptureNodeCapability>
    }
    let limits: Limits
    private var reservations: [UUID: Reservation] = [:]

    init(limits: Limits = .standard) {
        precondition(limits.nodes > 0 && limits.videoStreams >= 0 && limits.videoStreams <= limits.nodes)
        self.limits = limits
    }

    mutating func admit(_ hello: CaptureNodeHello, connectionID: UUID) -> Decision {
        if let current = reservations.values.first(where: { $0.connectionID == connectionID }) {
            guard current.nodeID == hello.nodeID else { return .rejected(.identityChanged) }
            guard current.capabilities == hello.capabilities else { return .rejected(.capabilitiesChanged) }
            return .duplicate
        }
        let others = reservations.values.filter { $0.nodeID != hello.nodeID }
        guard others.count < limits.nodes else { return .rejected(.nodeLimit) }
        if hello.capabilities.contains(.video),
           others.filter({ $0.capabilities.contains(.video) }).count >= limits.videoStreams {
            return .rejected(.videoLimit)
        }
        reservations[hello.nodeID] = Reservation(nodeID: hello.nodeID, connectionID: connectionID, capabilities: hello.capabilities)
        return .accepted
    }

    mutating func remove(connectionID: UUID) {
        reservations = reservations.filter { $0.value.connectionID != connectionID }
    }
    mutating func reset() { reservations.removeAll() }
}

struct NodeAdmissionEvent: Codable, Identifiable {
    var id = UUID()
    let nodeID: UUID
    let name: String
    let reason: NodeAdmissionPolicy.Rejection
    let occurredAt: Date
}
