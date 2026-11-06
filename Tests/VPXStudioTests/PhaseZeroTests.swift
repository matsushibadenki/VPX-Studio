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
        let completed = expectation(description: "Fixed replay completes")
        let source = try BenchmarkVideoSource()
        source.onComplete = { completed.fulfill() }
        source.onFailure = { error in XCTFail(error.localizedDescription); completed.fulfill() }
        try source.start()
        wait(for: [completed], timeout: 10)
        source.stop()
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
