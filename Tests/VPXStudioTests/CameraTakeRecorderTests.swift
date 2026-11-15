import XCTest
import AVFoundation
@testable import VPXStudio

final class CameraTakeRecorderTests: XCTestCase {
    @MainActor
    func testRecordsOnlySelectedSessionAndPublishesPlayableSealedTake() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = try StudioModel().takeSnapshotRequest()
        let source = UUID(), session = UUID()
        let recorder = try CameraTakeRecorder(request: request, parent: parent, sourceID: source)
        let store = LatestVideoFrameStore()
        store.selectSource(source)
        store.beginSession(sourceID: source, sessionID: session)
        XCTAssertTrue(store.startRecording(recorder, sourceID: source))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        func frame(_ i: Int64) -> VideoFrame {
            let time = CMTime(value: i, timescale: 30)
            return VideoFrame(identifier: UInt64(i), captureTime: time, hostReceiveTime: time,
                colorMetadata: .init(colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil),
                pixelBuffer: pixelBuffer, quality: .nominal)
        }
        store.put(frame(1), sourceID: source, sessionID: UUID())
        store.put(frame(2), sourceID: source, sessionID: session)
        store.put(frame(3), sourceID: source, sessionID: session)
        store.beginSession(sourceID: source, sessionID: UUID())
        store.put(frame(4), sourceID: source)
        _ = store.stopRecording()
        let url = try await recorder.finish()
        let review = try await TakeReviewService().inspect(directory: url)
        XCTAssertTrue(review.allVerified)
        XCTAssertEqual(review.manifest.provenance?.kind, .recording)
        let media = try review.manifest.verifiedPlaybackURL(relativePath: "camera.mov", in: url)
        let playable = try await AVURLAsset(url: media).load(.isPlayable)
        XCTAssertTrue(playable)
        let stats = try JSONDecoder().decode(CameraTakeRecorder.Statistics.self,
            from: Data(contentsOf: url.appendingPathComponent("recording.json")))
        XCTAssertEqual(stats.frames, 2)
        XCTAssertEqual(stats.sourceID, source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [url.lastPathComponent])
    }

    @MainActor
    func testEmptyRecordingDoesNotPublishTake() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        var recorder: CameraTakeRecorder? = try CameraTakeRecorder(request: StudioModel().takeSnapshotRequest(),
            parent: parent, sourceID: UUID())
        do { _ = try await recorder?.finish(); XCTFail("Empty recording") }
        catch CameraTakeRecorder.Failure.noFrames {}
        recorder = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).allSatisfy { $0.hasPrefix(".") })
    }
}
