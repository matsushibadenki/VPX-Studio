import XCTest
@testable import VPXStudio

final class DiagnosticsEventHistoryTests: XCTestCase {
    func testTransitionsSuppressRepeatedPollsAndRecordRecovery() {
        var history = DiagnosticsEventHistory()
        history.observe(stream: .videoInput, state: "active", hostTime: 1)
        history.observe(stream: .videoInput, state: "active", hostTime: 2)
        history.observe(stream: .videoInput, state: "stale", hostTime: 3)
        history.observe(stream: .videoInput, state: "active", hostTime: 4)
        XCTAssertEqual(history.events.count, 3)
        XCTAssertNil(history.events[0].previousState)
        XCTAssertEqual(history.events[2].previousState, "stale")
        XCTAssertEqual(history.events[2].hostMonotonicNanoseconds, 4)
    }

    func testNodeAndStreamIsolationWithBoundedRetention() throws {
        var history = DiagnosticsEventHistory(capacity: 2)
        let a = UUID(), b = UUID()
        history.observe(stream: .clock, nodeID: a, state: "current", hostTime: 1)
        history.observe(stream: .clock, nodeID: b, state: "current", hostTime: 2)
        history.observe(stream: .tracking, nodeID: a, state: "lost", hostTime: 3)
        XCTAssertEqual(history.events.map(\.sequence), [2, 3])
        XCTAssertEqual(history.discardedEventCount, 1)
        history.observe(stream: .clock, nodeID: a, state: "current", hostTime: 4)
        XCTAssertEqual(history.events.count, 2)
        let encoder = JSONEncoder()
        let data = try encoder.encode(history.events)
        XCTAssertEqual(try JSONDecoder().decode([DiagnosticsEventHistory.Event].self, from: data), history.events)
    }
}
