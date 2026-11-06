import XCTest
import MetalKit
import CoreMedia
@testable import VPXStudio

final class TemporalMatteTests: XCTestCase {
    func key(source: UUID, width: Int = 32, normalization: [Float] = [0.12,0.2,0.5]) -> TemporalMattePolicy.Key {
        .init(sourceID: source,width: width,height: 32,pixelFormat: kCVPixelFormatType_32BGRA,normalization: normalization)
    }
    func testSameFrameReusesHistoryAndNewFrameBlends() {
        var policy = TemporalMattePolicy(); let key = key(source: UUID())
        XCTAssertEqual(policy.next(key: key,sequence: 1,captureTime: 1,enabled: true),.reset)
        XCTAssertEqual(policy.next(key: key,sequence: 1,captureTime: 1,enabled: true),.reuse)
        XCTAssertEqual(policy.next(key: key,sequence: 2,captureTime: 1.02,enabled: true),.blend)
    }
    func testSourceNormalizationAndSizeChangesResetHistory() {
        var policy = TemporalMattePolicy(); let source = UUID()
        _ = policy.next(key: key(source: source),sequence: 1,captureTime: 1,enabled: true)
        XCTAssertEqual(policy.next(key: key(source: source,width: 64),sequence: 2,captureTime: 1.02,enabled: true),.reset)
        XCTAssertEqual(policy.next(key: key(source: source,width: 64,normalization: [0.13]),sequence: 3,captureTime: 1.04,enabled: true),.reset)
        XCTAssertEqual(policy.next(key: key(source: UUID()),sequence: 4,captureTime: 1.06,enabled: true),.reset)
        var degraded = key(source: source)
        _ = policy.next(key: degraded,sequence: 5,captureTime: 1.08,enabled: true)
        degraded.quality = .degraded
        XCTAssertEqual(policy.next(key: degraded,sequence: 6,captureTime: 1.1,enabled: true),.reset)
    }
    func testGapsReorderingAndDisableDoNotReuseStalePixels() {
        var policy = TemporalMattePolicy(); let key = key(source: UUID())
        _ = policy.next(key: key,sequence: 1,captureTime: 1,enabled: true)
        XCTAssertEqual(policy.next(key: key,sequence: 2,captureTime: 1.2,enabled: true),.reset)
        XCTAssertEqual(policy.next(key: key,sequence: 1,captureTime: 1.21,enabled: true),.reset)
        XCTAssertEqual(policy.next(key: key,sequence: 2,captureTime: 1.22,enabled: false),.disabled)
        XCTAssertEqual(policy.next(key: key,sequence: 3,captureTime: 1.23,enabled: true),.reset)
        XCTAssertEqual(policy.next(key: key,sequence: 4,captureTime: 1.1,enabled: true),.reset)
    }
    func testUnknownOrInvalidTimingAndParametersDisableHistory() {
        var policy = TemporalMattePolicy(); let source = UUID()
        XCTAssertEqual(policy.next(key: nil,sequence: 1,captureTime: 1,enabled: true),.disabled)
        XCTAssertEqual(policy.next(key: key(source: source),sequence: 1,captureTime: nil,enabled: true),.disabled)
        XCTAssertEqual(policy.next(key: key(source: source),sequence: 1,captureTime: .nan,enabled: true),.disabled)
        XCTAssertEqual(policy.next(key: key(source: source,normalization: [.infinity]),sequence: 1,captureTime: 1,enabled: true),.disabled)
    }

    func testGPUStabilizesEdgesWithoutAccumulatingOnRepeatedDraws() throws {
        let filtered = try MatteHarness(enabled: true), instant = try MatteHarness(enabled: false)
        let source = UUID()
        let first = try filtered.render(sequence: 1,time: 1,source: source,red: 51,green: 102)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode,.reset)
        let raw = try instant.render(sequence: 2,time: 1.02,source: source,red: 51,green: 104)
        let blended = try filtered.render(sequence: 2,time: 1.02,source: source,red: 51,green: 104)
        XCTAssertGreaterThan(blended,raw+3)
        XCTAssertLessThan(blended,first)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode,.blend)
        XCTAssertEqual(try filtered.render(sequence: 2,time: 1.02,source: source,red: 51,green: 104),blended)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode,.reuse)
        XCTAssertEqual(try filtered.render(sequence: 3,time: 1.04,source: source,red: 51,green: 0),255)
        XCTAssertEqual(try filtered.render(sequence: 4,time: 1.06,source: source,red: 51,green: 255),0)
        let switched = try filtered.render(sequence: 5,time: 1.08,source: UUID(),red: 51,green: 104)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode,.reset)
        XCTAssertEqual(switched,raw)
        filtered.settings.temporalMatteEnabled = false
        XCTAssertEqual(try filtered.render(sequence: 6,time: 1.1,source: source,red: 51,green: 104),raw)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode,.disabled)
        filtered.settings.temporalMatteEnabled = true
        XCTAssertEqual(try filtered.render(sequence: 7,time: 1.12,source: source,red: 51,green: 104),raw)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode,.reset)
    }

    func testGPUMotionGateUsesCurrentMaskRatherThanDraggingHistory() throws {
        let filtered = try MatteHarness(enabled: true), instant = try MatteHarness(enabled: false)
        let source = UUID()
        _ = try filtered.render(sequence: 1,time: 1,source: source,red: 51,green: 104)
        let raw = try instant.render(sequence: 2,time: 1.02,source: source,red: 76,green: 127)
        let moved = try filtered.render(sequence: 2,time: 1.02,source: source,red: 76,green: 127)
        XCTAssertEqual(moved,raw)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode,.blend)
    }
}

private final class MatteHarness {
    let pipeline: MetalFramePipeline
    let target: MTLTexture
    let metrics = RealtimeMetricsStore()
    var settings = StudioRenderSettings()
    init(enabled: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        pipeline = try MetalFramePipeline(device: device,pixelFormat: .bgra8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 16,height: 16,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        settings.chromaEnabled = true; settings.temporalMatteEnabled = enabled
        settings.inputEncoding = .linear; settings.debugView = .matte; settings.profile = .reviewCinema
    }
    func render(sequence: UInt64, time: Double, source: UUID, red: UInt8, green: UInt8) throws -> Int {
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,16,16,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true,kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&optionalBuffer),kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer,[])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let color = UInt32(red) | UInt32(green)<<8 | UInt32(red)<<16 | 0xFF000000
        for y in 0..<16 {
            base.advanced(by: y*CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self).initialize(repeating: color,count: 16)
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let captured = CMTime(seconds: time,preferredTimescale: 1_000_000)
        let frame = VideoFrame(identifier: sequence,captureTime: captured,hostReceiveTime: captured,
            colorMetadata: .init(colorPrimaries: nil,transferFunction: nil,yCbCrMatrix: nil),pixelBuffer: buffer,
            quality: .nominal,telemetry: FrameTelemetry(captured: time))
        let command = try pipeline.encode(frame: frame,target: target,settings: settings,metrics: metrics,now: time+0.02,frameSourceID: source)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed)
        XCTAssertEqual(metrics.read().protection,.normal)
        var bytes = [UInt8](repeating: 0,count: 16*16*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: 16*4,from: MTLRegionMake2D(0,0,16,16),mipmapLevel: 0) }
        return Int(bytes[0])
    }
}
