import XCTest
import CoreMedia
import CoreVideo
@testable import VPXStudio

final class VideoSourceSelectionTests: XCTestCase {
    private func frame(_ id: UInt64) throws -> VideoFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        return VideoFrame(identifier: id, captureTime: .zero, hostReceiveTime: .zero,
            colorMetadata: .init(colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil),
            pixelBuffer: try XCTUnwrap(pixelBuffer), quality: .nominal)
    }

    func testSelectionIsolationAndLateCallbacks() throws {
        let store = LatestVideoFrameStore()
        let a = UUID(), b = UUID()
        store.put(try frame(1), sourceID: a)
        XCTAssertNil(store.read())
        store.selectSource(a)
        store.put(try frame(2), sourceID: a)
        store.put(try frame(3), sourceID: b)
        XCTAssertEqual(store.read()?.identifier, 2)
        store.selectSource(b)
        XCTAssertNil(store.read())
        store.put(try frame(4), sourceID: a)
        XCTAssertNil(store.read())
        store.put(try frame(5), sourceID: b)
        XCTAssertEqual(store.read()?.identifier, 5)
        store.selectSource(b)
        XCTAssertEqual(store.read()?.identifier, 5)
        store.selectSource(nil)
        store.put(try frame(6), sourceID: b)
        XCTAssertNil(store.read())
    }

    func testReconnectRejectsOldDecoderCompletionAndDelayedDisconnect() throws {
        let core = RealtimeCore()
        let node = UUID(), old = UUID(), replacement = UUID()
        let store = core.latestVideoFrame
        store.selectSource(node)
        store.beginSession(sourceID: node, sessionID: old)
        core.ingest(try frame(99), from: node, sessionID: old)
        XCTAssertEqual(store.read()?.identifier, 99)
        store.beginSession(sourceID: node, sessionID: replacement)
        XCTAssertNil(store.read())
        core.ingest(try frame(100), from: node, sessionID: old)
        XCTAssertNil(store.read())
        // The new Node session may reset its sequence to one.
        core.ingest(try frame(1), from: node, sessionID: replacement)
        store.endSession(sourceID: node, sessionID: old)
        XCTAssertEqual(store.read()?.identifier, 1)
        store.endSession(sourceID: node, sessionID: replacement)
        XCTAssertNil(store.read())
        core.ingest(try frame(2), from: node, sessionID: replacement)
        XCTAssertNil(store.read())
    }

    func testOtherNodeReconnectAndDisconnectDoNotClearSelectedVideo() throws {
        let store = LatestVideoFrameStore()
        let a = UUID(), b = UUID(), aSession = UUID(), bSession = UUID()
        store.selectSource(a)
        store.beginSession(sourceID: a, sessionID: aSession)
        store.put(try frame(10), sourceID: a, sessionID: aSession)
        store.beginSession(sourceID: b, sessionID: bSession)
        store.put(try frame(11), sourceID: b, sessionID: bSession)
        store.endSession(sourceID: b, sessionID: bSession)
        XCTAssertEqual(store.read()?.identifier, 10)
        // Missing/wrong connection tokens cannot bypass the active reservation.
        store.put(try frame(12), sourceID: a)
        store.put(try frame(13), sourceID: a, sessionID: UUID())
        XCTAssertEqual(store.read()?.identifier, 10)
    }

    func testPausedMailboxRejectsInFlightFramesAndResumesWithoutCachedVideo() throws {
        let store = LatestVideoFrameStore()
        let node = UUID(), connection = UUID()
        store.selectSource(node)
        store.beginSession(sourceID: node, sessionID: connection)
        store.put(try frame(1), sourceID: node, sessionID: connection)
        store.setSuspended(true, sourceID: node, sessionID: connection)
        store.put(try frame(2), sourceID: node, sessionID: connection)
        XCTAssertNil(store.read())
        store.setSuspended(false, sourceID: node, sessionID: UUID())
        store.put(try frame(3), sourceID: node, sessionID: connection)
        XCTAssertNil(store.read())
        store.setSuspended(false, sourceID: node, sessionID: connection)
        XCTAssertNil(store.read())
        store.put(try frame(4), sourceID: node, sessionID: connection)
        XCTAssertEqual(store.read()?.identifier, 4)
    }
}
