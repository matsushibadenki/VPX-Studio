import XCTest
import CoreMedia
import CoreVideo
import MetalKit
import CryptoKit
@testable import VPXStudio

final class PhaseZeroTests: XCTestCase {
    func testClockMappingInvertsOffsetAndDrift() throws {
        // host=2s, reference=1s, offset=10ms, drift=1000ppm -> node=2.011s.
        XCTAssertEqual(try XCTUnwrap(HostClockMapping.hostTime(nodeNanoseconds: 2_011_000_000,
            offset: 10_000_000, driftPPM: 1000, referenceHost: 1_000_000_000)), 2_000_000_000, accuracy: 0.001)
        XCTAssertNil(HostClockMapping.hostTime(nodeNanoseconds: 1, offset: .nan, driftPPM: 0, referenceHost: 0))
        XCTAssertNil(HostClockMapping.hostTime(nodeNanoseconds: 1, offset: 0, driftPPM: -1_000_000, referenceHost: 0))
        XCTAssertNil(FrameTelemetry.milliseconds(from: 2, to: 1))
        XCTAssertNil(FrameTelemetry.milliseconds(from: nil, to: 1))
        XCTAssertEqual(try XCTUnwrap(FrameTelemetry.milliseconds(from: 1, to: 1.02)), 20, accuracy: 0.001)
    }

    func testPipelineBoundariesAndCopyAccounting() throws {
        let source = try BenchmarkVideoSource()
        var frame = try source.makeFrame(index: 0, hostNanoseconds: 1_000_000_000)
        frame.telemetry = FrameTelemetry(captured: 1, received: 1.01, decodeStarted: 1.02,
            decodeCompleted: 1.03, knownCPUCopyCount: 1, knownCPUCopyBytes: 128)
        let metrics = RealtimeMetricsStore()
        metrics.recordInput(frame, renderTime: 1.04, importMilliseconds: 0.2)
        metrics.recordInput(frame, renderTime: 1.05, importMilliseconds: 0.3)
        metrics.recordPresentation(at: 1.06, submitted: 1.04, captureTime: 1)
        metrics.sampleMemory()
        let values = metrics.read().pipeline
        XCTAssertEqual(values.observedFrames, 1)
        XCTAssertEqual(values.knownCPUCopyCount, 1)
        XCTAssertEqual(values.knownCPUCopyBytes, 128)
        XCTAssertEqual(try XCTUnwrap(values.captureToReceiveMilliseconds), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(values.receiveToDecodeMilliseconds), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(values.decodeMilliseconds), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(values.renderToPresentMilliseconds), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(values.captureToPresentMilliseconds), 60, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(values.residentMemoryBytes), 0)
        XCTAssertEqual(values.ioSurfaceFrames, 1)
        let reused = VideoFrame(identifier: 1, captureTime: frame.captureTime, hostReceiveTime: frame.hostReceiveTime,
            colorMetadata: frame.colorMetadata, pixelBuffer: frame.pixelBuffer, quality: .nominal,
            telemetry: FrameTelemetry(captured: 2, received: 2))
        metrics.recordInput(reused, renderTime: 2.01, importMilliseconds: 0.1)
        XCTAssertEqual(metrics.read().pipeline.pixelBufferReuseCount, 1)
        XCTAssertEqual(metrics.read().pipeline.ioSurfaceReuseCount, 1)
        XCTAssertNil(metrics.read().pipeline.decodeMilliseconds)
        XCTAssertEqual(metrics.read().pipeline.observedFrames, 2)
    }

    func testEncodingAndTransportAreSeparateFromDecoding() throws {
        let source = try BenchmarkVideoSource()
        var frame = try source.makeFrame(index: 0, hostNanoseconds: 1_000_000_000)
        frame.telemetry = FrameTelemetry(captured: 1, received: 1.05, encodeCompleted: 1.02,
                                        decodeStarted: 1.07, decodeCompleted: 1.08)
        let metrics = RealtimeMetricsStore()
        metrics.recordInput(frame, renderTime: 1.09, importMilliseconds: 0.1)
        XCTAssertEqual(try XCTUnwrap(metrics.read().pipeline.captureToEncodeMilliseconds), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.read().pipeline.transportMilliseconds), 30, accuracy: 0.001)
    }

    func testFixedFixturePixelsAndPoseLogAreRepeatable() throws {
        let source = try BenchmarkVideoSource()
        let a = try source.makeFrame(index: 0, hostNanoseconds: 100)
        let b = try source.makeFrame(index: 0, hostNanoseconds: 200)
        let c = try source.makeFrame(index: 1, hostNanoseconds: 300)
        func pixels(_ frame: VideoFrame) -> Data {
            CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
            return Data(bytes: CVPixelBufferGetBaseAddress(frame.pixelBuffer)!, count: 640 * 4)
        }
        XCTAssertEqual(pixels(a).prefix(4), Data([32, 0, 0, 255]))
        XCTAssertEqual(SHA256.hash(data: pixels(a)), SHA256.hash(data: pixels(b)))
        XCTAssertNotEqual(SHA256.hash(data: pixels(a)), SHA256.hash(data: pixels(c)))
        XCTAssertEqual(source.fixture.poses.count, 120)
        XCTAssertEqual(source.fixture.poses.last?.offsetNanoseconds, 1_983_333_333)
        XCTAssertEqual(source.fixture.poses[60].translationMeters, [0, 1.5, 0])
        XCTAssertThrowsError(try source.makeFrame(index: 120, hostNanoseconds: 400))
    }

    func testFiniteReplayCompletes() throws {
        // Validate finite delivery, not wall-clock 60fps performance. A short
        // fixture remains reliable when background timer events are coalesced.
        let completed = expectation(description: "Fixed replay completes")
        let frames = expectation(description: "All frames delivered")
        let poses = expectation(description: "All poses delivered")
        frames.expectedFulfillmentCount = 3; frames.assertForOverFulfill = true
        poses.expectedFulfillmentCount = 3; poses.assertForOverFulfill = true
        let fixture = BenchmarkFixture(id: "finite-completion-test",width: 16,height: 16,framesPerSecond: 60,
            poses: Array(BenchmarkFixture.standard.poses.prefix(3)))
        let source = try BenchmarkVideoSource(fixture: fixture)
        source.onFrame = { frame in XCTAssertLessThan(frame.identifier,3); frames.fulfill() }
        source.onPose = { _, _ in poses.fulfill() }
        source.onComplete = { completed.fulfill() }
        source.onFailure = { error in XCTFail(error.localizedDescription); completed.fulfill() }
        try source.start()
        wait(for: [frames,poses,completed], timeout: 10)
        source.stop()
    }

    func testReplayPatternAcrossCheckerAndChannelBoundaries() throws {
        let source = try BenchmarkVideoSource()
        for index in [0,1,119] {
            let frame = try source.makeFrame(index: index,hostNanoseconds: 100)
            CVPixelBufferLockBaseAddress(frame.pixelBuffer,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer,.readOnly) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame.pixelBuffer))
            let stride = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
            for y in [0,39,40,79,255,359] {
                let row = base.advanced(by: y*stride).assumingMemoryBound(to: UInt32.self)
                for x in [0,39,40,79,255,639] {
                    let expected: UInt32 = 0xFF000000 | UInt32((x+index*3)%256)<<16 | UInt32(y%256)<<8 |
                        UInt32((x/40+y/40)%2 == 0 ? 32 : 224)
                    XCTAssertEqual(row[x],expected,"frame \(index), (\(x), \(y))")
                }
            }
        }
    }

    func testReplayRejectsInvalidDimensionsAndSchedulingRate() {
        for fixture in [
            BenchmarkFixture(id: "zero-width",width: 0,height: 16,framesPerSecond: 60,poses: BenchmarkFixture.standard.poses),
            BenchmarkFixture(id: "zero-rate",width: 16,height: 16,framesPerSecond: 0,poses: BenchmarkFixture.standard.poses),
            BenchmarkFixture(id: "empty",width: 16,height: 16,framesPerSecond: 60,poses: [])
        ] {
            XCTAssertThrowsError(try BenchmarkVideoSource(fixture: fixture))
        }
    }

    func testPoseAgeUsesCaptureTimeNotArrivalTime() {
        let health = PoseHealth(lastAcceptedNanoseconds: 900_000_000, quality: .nominal,
                               capturedHostNanoseconds: 100_000_000)
        XCTAssertEqual(health.effectiveQuality(now: 901_000_000, clock: .current), .lost)
        XCTAssertEqual(health.captureAgeMilliseconds(now: 901_000_000), 801)
    }

    func testReleaseBaselineMatchesDeploymentTargets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Config/ReleaseBaseline.json"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(config["macOSMinimum"] as? String, "15.0")
        XCTAssertEqual(config["iOSMinimum"] as? String, "18.0")
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(".macOS(.v15)"))
        XCTAssertTrue(manifest.contains(".iOS(.v18)"))
    }

    func testMetalPipelineLoadsBundledShader() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        XCTAssertNotNil(MetalRenderer(pixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float,
                                     latestVideoFrame: LatestVideoFrameStore(), metrics: RealtimeMetricsStore()))
    }
}
