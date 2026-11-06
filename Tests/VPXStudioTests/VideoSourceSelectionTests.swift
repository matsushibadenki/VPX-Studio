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
}
