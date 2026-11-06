import Foundation

/// Main-actor owned by StudioModel. Records transitions rather than every poll.
struct DiagnosticsEventHistory {
    enum Stream: String, Codable, Sendable { case videoInput, clock, tracking, gpu, protection }

    struct Event: Codable, Equatable, Sendable {
        let sequence: UInt64
        let timestamp: Date
        let hostMonotonicNanoseconds: UInt64
        let nodeID: UUID?
        let stream: Stream
        let previousState: String?
        let state: String
    }

    private struct Key: Hashable {
        let nodeID: UUID?
        let stream: Stream
    }

    let capacity: Int
    private(set) var events: [Event] = []
    private(set) var discardedEventCount: UInt64 = 0
    private var states: [Key: String] = [:]
    private var nextSequence: UInt64 = 1

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    mutating func observe(stream: Stream, nodeID: UUID? = nil, state: String,
                          at timestamp: Date = Date(), hostTime: UInt64) {
        let key = Key(nodeID: nodeID, stream: stream)
        let previous = states[key]
        guard previous != state else { return }
        states[key] = state
        events.append(Event(sequence: nextSequence, timestamp: timestamp,
            hostMonotonicNanoseconds: hostTime, nodeID: nodeID, stream: stream,
            previousState: previous, state: state))
        nextSequence &+= 1
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
            discardedEventCount &+= 1
        }
    }
}
