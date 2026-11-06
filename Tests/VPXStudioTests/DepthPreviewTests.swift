import XCTest
import MetalKit
import VPXCaptureProtocol
@testable import VPXStudio

final class DepthPreviewTests: XCTestCase {
    func input(source: UUID, sequence: UInt64 = 1, values: [Float] = [.nan,1,5,10], time: Double = 1) throws -> DepthPreviewInput {
        var depth = Data()
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { depth.append(contentsOf: $0) }
        }
        let packet = try CaptureDepthPacket(header: .init(sequence: sequence,captureTimeNanoseconds: UInt64(sequence)*1_000_000,
            width: 2,height: 2,depthEncoding: "depth-float32-le",confidenceEncoding: "confidence-uint8"),
            depth: depth,confidence: Data([0,1,2,2]))
        return .init(sourceID: source,packet: packet,capturedHostSeconds: time)
    }
    func testSourceAndClockFreshnessGates() throws {
        let source = UUID(), frame = try input(source: UUID())
        XCTAssertFalse(frame.isCurrent(sourceID: source,now: 1.1))
        XCTAssertTrue(frame.isCurrent(sourceID: frame.sourceID,now: 1.1))
        XCTAssertFalse(frame.isCurrent(sourceID: frame.sourceID,now: 1.501))
        XCTAssertFalse(frame.isCurrent(sourceID: frame.sourceID,now: 0.9))
        XCTAssertFalse(frame.isCurrent(sourceID: nil,now: 1.1))
        XCTAssertFalse(frame.isCurrent(sourceID: frame.sourceID,now: .nan))
        XCTAssertFalse(try input(source: source,time: -1).isCurrent(sourceID: source,now: 0))
    }
    func testUploadsOnceAndNeverOverwritesInFlightTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let source = UUID(), cache = DepthPreviewTextureCache(device: device)
        let frame = try input(source: source,values: [1,1,1,1])
        let first = try XCTUnwrap(cache.textures(for: frame,sourceID: source,now: 1.1))
        let repeated = try XCTUnwrap(cache.textures(for: frame,sourceID: source,now: 1.2))
        XCTAssertTrue(first.depth === repeated.depth); XCTAssertEqual(cache.uploadCount,1)
        let second = try XCTUnwrap(cache.textures(for: input(source: source,sequence: 2,values: [2,2,2,2]),sourceID: source,now: 1.2))
        XCTAssertFalse(first.depth === second.depth); XCTAssertEqual(cache.uploadCount,2)
        var old: Float = 0
        first.depth.getBytes(&old,bytesPerRow: 4,from: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0)
        XCTAssertEqual(old,1)
        XCTAssertNil(try cache.textures(for: frame,sourceID: UUID(),now: 1.2))
        XCTAssertNil(try cache.textures(for: frame,sourceID: source,now: 2))
    }
    func testGPUConfidencePaletteAndAspectRatio() throws {
        let harness = try DepthHarness(), source = UUID()
        harness.settings.depthPreview = try input(source: source)
        harness.settings.debugView = .depthConfidence
        let pixels = try harness.render(source: source,now: 1.1)
        XCTAssertEqual(harness.metrics.read().depthPreview?.available,true)
        assertColor(pixels,x: 12,y: 4,expected: [255,0,0])
        assertColor(pixels,x: 20,y: 4,expected: [255,166,0])
        assertColor(pixels,x: 12,y: 12,expected: [0,255,0])
        assertColor(pixels,x: 2,y: 8,expected: [0,0,0]) // Letterbox, not stretched.
    }
    func testGPUHeatMapMasksInvalidDepthAndUsesConfidence() throws {
        let harness = try DepthHarness(), source = UUID()
        harness.settings.depthPreview = try input(source: source)
        harness.settings.debugView = .depth
        var pixels = try harness.render(source: source,now: 1.1)
        assertColor(pixels,x: 12,y: 4,expected: [0,0,0])
        assertColor(pixels,x: 20,y: 4,expected: [115,45,13])
        assertColor(pixels,x: 12,y: 12,expected: [128,191,128])
        assertColor(pixels,x: 20,y: 12,expected: [0,64,255])
        harness.settings.depthPreview = try input(source: source,sequence: 2,values: [.nan,1,.infinity,-1])
        pixels = try harness.render(source: source,now: 1.2)
        assertColor(pixels,x: 12,y: 12,expected: [0,0,0])
        assertColor(pixels,x: 20,y: 12,expected: [0,0,0])
    }
    func testStaleWrongSourceAndProductionNeverDisplayRawDepth() throws {
        let harness = try DepthHarness(), source = UUID()
        harness.settings.depthPreview = try input(source: source)
        harness.settings.debugView = .depthConfidence
        _ = try harness.render(source: source,now: 1.1)
        var pixels = try harness.render(source: source,now: 2)
        XCTAssertEqual(harness.metrics.read().depthPreview?.available,false)
        assertColor(pixels,x: 12,y: 12,expected: [4,4,4])
        pixels = try harness.render(source: UUID(),now: 1.2)
        XCTAssertEqual(harness.metrics.read().depthPreview?.available,false)
        assertColor(pixels,x: 12,y: 12,expected: [4,4,4])
        harness.settings.protectMissingInput = true
        pixels = try harness.render(source: source,now: 1.2)
        XCTAssertNil(harness.metrics.read().depthPreview)
        XCTAssertEqual(harness.metrics.read().protection,.inputLost)
        assertColor(pixels,x: 12,y: 12,expected: [6,2,3])
    }
    func assertColor(_ bytes: [UInt8], x: Int, y: Int, expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        let offset = (y*32+x)*4
        let actual = [Int(bytes[offset+2]),Int(bytes[offset+1]),Int(bytes[offset])]
        for i in 0..<3 { XCTAssertEqual(actual[i],expected[i],accuracy: 2,file: file,line: line) }
    }
}

private final class DepthHarness {
    let pipeline: MetalFramePipeline
    let target: MTLTexture
    let metrics = RealtimeMetricsStore()
    var settings = StudioRenderSettings()
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        pipeline = try MetalFramePipeline(device: device,pixelFormat: .bgra8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 32,height: 16,mipmapped: false)
        descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .shared
        target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        settings.profile = .reviewCinema
    }
    func render(source: UUID, now: Double) throws -> [UInt8] {
        let command = try pipeline.encode(frame: nil,target: target,settings: settings,metrics: metrics,now: now,frameSourceID: source)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed)
        var bytes = [UInt8](repeating: 0,count: 32*16*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: 32*4,from: MTLRegionMake2D(0,0,32,16),mipmapLevel: 0) }
        return bytes
    }
}
