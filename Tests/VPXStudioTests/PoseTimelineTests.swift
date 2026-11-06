import XCTest
import MetalKit
import CoreMedia
import simd
@testable import VPXStudio

final class PoseTimelineTests: XCTestCase {
    func transform(_ x: Float, angle: Float = 0) -> simd_float4x4 {
        var matrix = simd_float4x4(simd_quatf(angle: angle,axis: SIMD3<Float>(0,1,0)))
        matrix.columns.3 = SIMD4(x,0,0,1)
        return matrix
    }
    func history(nominal: Bool = true) -> PoseTimeline {
        var timeline = PoseTimeline()
        timeline.append(time: 1,transform: transform(0),nominal: nominal)
        timeline.append(time: 1.02,transform: transform(0.1,angle: 0.1),nominal: nominal)
        return timeline
    }
    func testInterpolatesPositionAndRotationAtVideoTime() throws {
        let result = try XCTUnwrap(history().resolve(at: 1.01,now: 1.1,maximumAge: 0.5))
        XCTAssertEqual(result.mode,.interpolated)
        XCTAssertEqual(result.transform[3].x,0.05,accuracy: 0.0001)
        XCTAssertEqual(simd_quatf(result.transform).angle,0.05,accuracy: 0.001)
        XCTAssertEqual(history().resolve(at: 1.02,now: 1.1,maximumAge: 0.5)?.mode,.measured)
    }
    func testBoundedPredictionAndMeasuredError() throws {
        var timeline = history()
        let result = try XCTUnwrap(timeline.resolve(at: 1.03,now: 1.04,maximumAge: 0.5))
        XCTAssertEqual(result.mode,.predicted)
        XCTAssertEqual(result.transform[3].x,0.15,accuracy: 0.0001)
        XCTAssertEqual(result.horizonMilliseconds,10,accuracy: 0.0001)
        XCTAssertEqual(simd_quatf(result.transform).angle,0.15,accuracy: 0.001)
        XCTAssertNotNil(timeline.resolve(at: 1.05,now: 1.05,maximumAge: 0.5))
        XCTAssertNil(timeline.resolve(at: 1.0501,now: 1.06,maximumAge: 0.5))
        timeline.append(time: 1.04,transform: transform(0.21,angle: 0.22),nominal: true)
        XCTAssertEqual(try XCTUnwrap(timeline.predictionErrorMeters),0.01,accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(timeline.predictionErrorRadians),0.02,accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(timeline.predictionErrorHorizonMilliseconds),20,accuracy: 0.0001)
    }
    func testRejectsStaleMissingFutureAndNonNominalPrediction() {
        XCTAssertNil(PoseTimeline().resolve(at: 1,now: 1,maximumAge: 0.5))
        XCTAssertNil(history().resolve(at: 0.99,now: 1.1,maximumAge: 0.5))
        XCTAssertNil(history().resolve(at: 1.01,now: 2,maximumAge: 0.5))
        XCTAssertNil(history().resolve(at: 1.03,now: 1.02,maximumAge: 0.5))
        XCTAssertNil(history().resolve(at: .nan,now: 1.1,maximumAge: 0.5))
        XCTAssertNil(history(nominal: false).resolve(at: 1.03,now: 1.1,maximumAge: 0.5))
        XCTAssertNotNil(history(nominal: false).resolve(at: 1.01,now: 1.1,maximumAge: 0.5))
    }
    func testTranslationAndRotationCapsAreIndependentOfTimeCap() {
        var translation = PoseTimeline()
        translation.append(time: 1,transform: transform(0),nominal: true)
        translation.append(time: 1.02,transform: transform(0.2),nominal: true)
        XCTAssertNil(translation.resolve(at: 1.05,now: 1.05,maximumAge: 0.5))
        var rotation = PoseTimeline()
        rotation.append(time: 1,transform: transform(0),nominal: true)
        rotation.append(time: 1.02,transform: transform(0,angle: 0.3),nominal: true)
        XCTAssertNil(rotation.resolve(at: 1.04,now: 1.04,maximumAge: 0.5))
    }
    func testDiscontinuitiesAndCapacityDoNotBridgeOldWorlds() {
        var timeline = history()
        timeline.append(time: 1.5,transform: transform(5),nominal: true)
        XCTAssertEqual(timeline.samples.count,1)
        XCTAssertNil(timeline.resolve(at: 1.2,now: 1.5,maximumAge: 0.5))
        timeline.append(time: 1.4,transform: transform(4),nominal: true)
        XCTAssertEqual(timeline.samples.count,1)
        for i in 0..<200 { timeline.append(time: 2+Double(i)*0.02,transform: transform(Float(i)*0.01),nominal: true) }
        XCTAssertEqual(timeline.samples.count,128)
        XCTAssertNil(timeline.resolve(at: 2,now: 6,maximumAge: 10))
        timeline.append(time: .nan,transform: transform(0),nominal: true)
        XCTAssertEqual(timeline.samples.count,128)
    }
    func testStageTransformAppliesAfterPoseSampling() throws {
        let alignment = PoseCameraAlignment(sourceID: UUID(),history: history(),stageFromNodeWorld: transform(5),maximumAge: 0.5)
        XCTAssertEqual(try XCTUnwrap(alignment.resolve(videoCaptureTime: 1.01,now: 1.1)).transform[3].x,5.05,accuracy: 0.0001)
        XCTAssertNil(alignment.resolve(videoCaptureTime: nil,now: 1.1))
    }
    func testGPUProtectsMissingOrWrongSourcePoseAndRecordsInterpolation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let pipeline = try MetalFramePipeline(device: device,pixelFormat: .bgra8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 32,height: 32,mipmapped: false)
        descriptor.usage = [.renderTarget,.shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,32,32,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true,kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&buffer)
        XCTAssertEqual(status,kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image,[])
        if let base = CVPixelBufferGetBaseAddress(image) { memset(base,0,CVPixelBufferGetDataSize(image)) }
        CVPixelBufferUnlockBaseAddress(image,[])
        let source = UUID()
        var settings = StudioRenderSettings()
        settings.inputEncoding = .sRGB; settings.profile = .reviewCinema
        settings.requirePoseAlignment = true
        settings.poseAlignment = PoseCameraAlignment(sourceID: source,history: history(),stageFromNodeWorld: transform(0),maximumAge: 0.5)
        let metrics = RealtimeMetricsStore()
        func render(captured: Double?, sourceID: UUID) throws {
            let frame = VideoFrame(identifier: 1,captureTime: .zero,hostReceiveTime: CMTime(seconds: 1.08,preferredTimescale: 1_000_000),
                colorMetadata: .init(colorPrimaries: nil,transferFunction: nil,yCbCrMatrix: nil),pixelBuffer: image,
                quality: .nominal,telemetry: FrameTelemetry(captured: captured))
            let command = try pipeline.encode(frame: frame,target: target,settings: settings,metrics: metrics,now: 1.1,frameSourceID: sourceID)
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status,.completed)
        }
        try render(captured: 1.01,sourceID: source)
        XCTAssertEqual(metrics.read().protection,.normal)
        XCTAssertEqual(metrics.read().poseAlignment?.mode,.interpolated)
        try render(captured: nil,sourceID: source)
        XCTAssertEqual(metrics.read().protection,.poseUnaligned)
        try render(captured: 1.01,sourceID: UUID())
        XCTAssertEqual(metrics.read().protection,.poseUnaligned)
        XCTAssertEqual(metrics.read().poseAlignment?.mode,.unavailable)
        try render(captured: 1.03,sourceID: source)
        XCTAssertEqual(metrics.read().protection,.normal)
        XCTAssertEqual(metrics.read().poseAlignment?.mode,.predicted)
        try render(captured: 1.06,sourceID: source)
        XCTAssertEqual(metrics.read().protection,.poseUnaligned)
    }
}
