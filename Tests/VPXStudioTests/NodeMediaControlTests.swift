import XCTest
import VPXCaptureProtocol
@testable import VPXStudio

final class NodeMediaControlTests: XCTestCase {
    func testPauseSuppressesMediaAndResumeAcknowledgementPrecedesNewMedia() throws {
        let gate = CaptureMediaTransmissionGate()
        let pause = CaptureNodeControlCommand(action: .suspendMedia)
        let resume = CaptureNodeControlCommand(action: .resumeMedia)
        var events: [String] = []
        gate.submit { events.append("first video") }
        gate.apply(pause) { result in
            XCTAssertEqual(result.commandID, pause.commandID); XCTAssertTrue(result.suspended)
            events.append("paused")
        }
        gate.submit { events.append("unexpected video") }
        gate.submit { events.append("unexpected depth") }
        // Pose/clock/diagnostics bypass the gate.
        events.append("pose")
        gate.apply(pause) { _ in events.append("duplicate pause") }
        gate.apply(resume) { result in
            XCTAssertEqual(result.commandID, resume.commandID); XCTAssertFalse(result.suspended)
            events.append("resumed")
        }
        gate.submit { events.append("new video") }
        XCTAssertEqual(events, ["first video", "paused", "pose", "duplicate pause", "resumed", "new video"])
        XCTAssertFalse(gate.apply(.init(action: .requestKeyFrame)) { _ in XCTFail("Unsupported acknowledgement") })
    }

    func testTimeoutBecomesUnknownAndLateOrWrongAcknowledgementsCannotConfirmRetry() throws {
        var state = NodeMediaControl()
        let first = try XCTUnwrap(state.request(suspend: true, now: 100))
        XCTAssertNil(state.request(suspend: false, now: 101))
        XCTAssertFalse(state.complete(.init(commandID: first.commandID, suspended: false)))
        state.expire(now: 3_000_000_099)
        XCTAssertNotNil(state.pending)
        state.expire(now: 3_000_000_100)
        XCTAssertTrue(state.failed); XCTAssertNil(state.suspended)
        let retry = try XCTUnwrap(state.request(suspend: true, now: 4_000_000_000))
        XCTAssertFalse(state.complete(.init(commandID: first.commandID, suspended: true)))
        XCTAssertEqual(state.pending?.commandID, retry.commandID)
        XCTAssertTrue(state.complete(.init(commandID: retry.commandID, suspended: true)))
        XCTAssertEqual(state.suspended, true); XCTAssertFalse(state.failed)
        XCTAssertFalse(state.complete(.init(commandID: retry.commandID, suspended: true)))
    }

    func testNodeIsolationAndNewConnectionReset() throws {
        var a = NodeMediaControl(), b = NodeMediaControl()
        let command = try XCTUnwrap(a.request(suspend: true, now: 1))
        XCTAssertFalse(b.complete(.init(commandID: command.commandID, suspended: true)))
        XCTAssertEqual(b.suspended, false)
        XCTAssertTrue(a.complete(.init(commandID: command.commandID, suspended: true)))
        a = NodeMediaControl()
        XCTAssertEqual(a.suspended, false)
        XCTAssertFalse(a.complete(.init(commandID: command.commandID, suspended: true)))
        let gate = CaptureMediaTransmissionGate()
        gate.apply(command) { _ in }
        gate.reset()
        var submitted = false
        gate.submit { submitted = true }
        XCTAssertTrue(submitted)
    }

    func testLateAcknowledgementCannotWinBetweenRefreshTicks() throws {
        var state = NodeMediaControl()
        let command = try XCTUnwrap(state.request(suspend: true, now: 1))
        XCTAssertFalse(state.complete(.init(commandID: command.commandID, suspended: true), now: 3_000_000_001))
        XCTAssertTrue(state.failed)
        XCTAssertNil(state.suspended)
        XCTAssertNil(state.pending)
        // The diagnostic representation preserves unknown, rather than false.
        let restored = try JSONDecoder().decode(NodeMediaControl.self, from: JSONEncoder().encode(state))
        XCTAssertNil(restored.suspended)
        XCTAssertTrue(restored.failed)
    }
}
