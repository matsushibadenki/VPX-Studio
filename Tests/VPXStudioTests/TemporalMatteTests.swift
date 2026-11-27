import XCTest
import MetalKit
import CoreMedia
import VPXCaptureProtocol
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
    func testMissingSequenceAndCaptureGenerationResetHistory() {
        var policy = TemporalMattePolicy()
        var input = key(source: UUID())
        input.sourceGeneration = UUID()
        XCTAssertEqual(policy.next(key: input, sequence: 1, captureTime: 1, enabled: true), .reset)
        XCTAssertEqual(policy.next(key: input, sequence: 3, captureTime: 1.02, enabled: true), .reset)
        input.sourceGeneration = UUID()
        XCTAssertEqual(policy.next(key: input, sequence: 4, captureTime: 1.04, enabled: true), .reset)
        XCTAssertEqual(policy.next(key: input, sequence: 5, captureTime: 1.06, enabled: true), .blend)
    }

    func testGPUDoesNotCarrySolidForegroundIntoNewFractionalBoundary() throws {
        let filtered = try MatteHarness(enabled: true)
        let instant = try MatteHarness(enabled: false)
        let source = UUID()
        XCTAssertEqual(try filtered.render(sequence: 1, time: 1, source: source, red: 51, green: 81), 255)
        let expected = try instant.render(sequence: 2, time: 1.02, source: source, red: 51, green: 91)
        XCTAssertLessThan(expected, 245)
        XCTAssertEqual(try filtered.render(sequence: 2, time: 1.02, source: source, red: 51, green: 91), expected)
        XCTAssertEqual(filtered.metrics.read().temporalMatteMode, .blend)
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

    func testGPUTracksTranslatedBoundaryWithUniquePatch() throws {
        let source = UUID()
        let previousColumns: [UInt8] = [0, 0, 0, 0, 0, 125, 102, 145, 200, 255, 255, 255, 255, 255, 255, 255]
        let previous = (0..<256).map { index -> UInt8 in
            let column = Int(previousColumns[index % 16])
            let rowVariation = index / 16 == 6 ? -18 : index / 16 == 8 ? 22 : 0
            return UInt8(clamping: column + rowVariation)
        }
        let current = (0..<256).map { index -> UInt8 in
            let x = index % 16
            let prior = x == 0 ? 0 : Int(previous[index - 1])
            return UInt8(clamping: prior + (x == 7 ? 5 : 0))
        }
        let instant = try MatteHarness(enabled: false)
        let filtered = try MatteHarness(enabled: true)
        let reference = try filtered.render(sequence: 1, time: 1, source: source, red: 51, green: 0,
                                            x: 6, y: 7, greenPixels: previous)
        let raw = try instant.render(sequence: 2, time: 1.02, source: source, red: 51, green: 0,
                                     x: 7, y: 7, greenPixels: current)
        let moved = try filtered.render(sequence: 2, time: 1.02, source: source, red: 51, green: 0,
                                        x: 7, y: 7, greenPixels: current)
        XCTAssertGreaterThan(moved, raw)
        XCTAssertLessThan(moved, reference)

        // The same horizontal edge repeated vertically has multiple equally good shifts.
        let ambiguous = try MatteHarness(enabled: true)
        var shifted = [UInt8(0)] + previousColumns.dropLast()
        shifted[7] += 5
        _ = try ambiguous.render(sequence: 1, time: 1, source: source, red: 51, green: 0,
                                 x: 6, y: 7, greenColumns: previousColumns)
        let ambiguousRaw = try instant.render(sequence: 2, time: 1.02, source: source, red: 51, green: 0,
                                               x: 7, y: 7, greenColumns: shifted)
        XCTAssertEqual(try ambiguous.render(sequence: 2, time: 1.02, source: source, red: 51, green: 0,
                                            x: 7, y: 7, greenColumns: shifted), ambiguousRaw)
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

    func testNormalizationComparisonShowsDistinctHalvesAndIsBypassedInProduction() throws {
        let harness = try MatteHarness(enabled: false)
        let source = UUID()
        harness.settings.chromaEnabled = false
        harness.settings.debugView = .colorConversion
        let left = try harness.render(sequence: 1, time: 1, source: source, red: 128, green: 128)
        let right = try harness.render(sequence: 2, time: 1.02, source: source, red: 128, green: 128, x: 15)
        XCTAssertEqual(Double(left), 55, accuracy: 1)
        XCTAssertEqual(Double(right), 128, accuracy: 1)
        harness.settings.protectMissingInput = true
        let production = try harness.render(sequence: 3, time: 1.04, source: source, red: 128, green: 128)
        XCTAssertEqual(Double(production), 128, accuracy: 1)
        harness.settings.protectMissingInput = false
        harness.settings.debugView = .lensCorrection
        harness.settings.camera.lens.radialDistortionK1 = 1
        let uncorrected = try harness.render(sequence: 4, time: 1.06, source: source, red: 128, green: 128)
        let correctedOutside = try harness.render(sequence: 5, time: 1.08, source: source, red: 128, green: 128, x: 15)
        XCTAssertEqual(Double(uncorrected), 128, accuracy: 1)
        XCTAssertEqual(correctedOutside, 0)
    }


    func testCompositeLUTChangesMetalOutputAndBypassesDiagnosticVideo() throws {
        let harness = try MatteHarness(enabled: false)
        let source = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cube")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(("LUT_3D_SIZE 2\n" + String(repeating: "0.1 0.2 0.25\n", count: 8)).utf8)
        try data.write(to: url)
        let lut = try CompositeLUT.load(url)
        XCTAssertEqual(lut.reference.name, url.lastPathComponent)
        XCTAssertTrue(lut.reference.isValid)
        harness.settings.compositeLUT = lut
        harness.settings.chromaEnabled = false
        harness.settings.debugView = .composite
        let graded = try harness.render(sequence: 1, time: 1, source: source, red: 128, green: 128)
        XCTAssertEqual(Double(graded), 64, accuracy: 1)
        harness.settings.debugView = .video
        let diagnostic = try harness.render(sequence: 2, time: 1.02, source: source, red: 128, green: 128)
        XCTAssertEqual(Double(diagnostic), 128, accuracy: 1)
        try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: url)
        XCTAssertThrowsError(try CompositeLUT.load(url))
    }


    func testGPUTrimapRefinesOnlyFractionalBoundaryPixels() throws {
        let harness = try MatteHarness(enabled: false)
        let source = UUID()
        let greens: [UInt8] = [0, 0, 0, 0, 0, 0, 102, 109, 102, 255, 255, 255, 255, 255, 255, 255]
        let baseline = try harness.render(sequence: 1, time: 1, source: source, red: 51, green: 109, x: 7)
        func sample(_ view: CompositeDebugView, x: Int) throws -> Int {
            harness.settings.debugView = view
            return try harness.render(sequence: 2, time: 1.02, source: source, red: 51, green: 109,
                                      x: x, greenColumns: greens)
        }

        XCTAssertEqual(try sample(.trimap, x: 0), 255)
        XCTAssertEqual(try sample(.trimap, x: 7), 128)
        XCTAssertEqual(try sample(.trimap, x: 15), 0)
        XCTAssertEqual(try sample(.matte, x: 0), 255)
        XCTAssertEqual(try sample(.matte, x: 15), 0)
        let refined = try sample(.matte, x: 7)
        XCTAssertGreaterThan(refined, baseline)
        XCTAssertLessThan(refined, baseline + 12)

        // An isolated fractional pixel has no eligible neighbors and retains its alpha.
        var isolated = greens
        isolated[6] = 0
        isolated[8] = 255
        XCTAssertEqual(try harness.render(sequence: 3, time: 1.04, source: source, red: 51, green: 109,
                                          x: 7, greenColumns: isolated), baseline)
    }


    func testGPUDepthGuidanceRequiresAlignedHighConfidenceSamples() throws {
        let harness = try MatteHarness(enabled: false)
        let source = UUID()
        let greens: [UInt8] = [0, 0, 0, 0, 0, 0, 109, 109, 102, 255, 255, 255, 255, 255, 255, 255]
        let stamp: UInt64 = 1_000_000
        func depth(sequence: UInt64, confidence: UInt8, width: Int = 8) throws -> DepthPreviewInput {
            var bytes = Data()
            for index in 0..<(width * 8) {
                var bits = Float(index % width < 4 ? 1 : 3).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            let packet = try CaptureDepthPacket(header: .init(sequence: sequence, captureTimeNanoseconds: stamp,
                width: UInt32(width), height: 8, depthEncoding: "depth-float32-le", confidenceEncoding: "confidence-uint8"),
                depth: bytes, confidence: Data(repeating: confidence, count: width * 8))
            return .init(sourceID: source, packet: packet, capturedHostSeconds: 1)
        }
        func render(x: Int = 7) throws -> Int {
            try harness.render(sequence: 1, time: 1, source: source, red: 51, green: 109, x: x,
                               greenColumns: greens, arKitCaptureNanoseconds: stamp)
        }

        let chroma = try render()
        harness.settings.depthPreview = try depth(sequence: 1, confidence: 2)
        XCTAssertLessThan(try render(), chroma)
        XCTAssertEqual(try render(x: 0), 255)
        XCTAssertEqual(try render(x: 15), 0)
        harness.settings.depthPreview = nil
        XCTAssertEqual(try render(), chroma)
        harness.settings.depthPreview = try depth(sequence: 1, confidence: 1)
        XCTAssertEqual(try render(), chroma)
        harness.settings.depthPreview = try depth(sequence: 2, confidence: 2)
        XCTAssertEqual(try render(), chroma)
        harness.settings.depthPreview = try depth(sequence: 1, confidence: 2, width: 4)
        XCTAssertEqual(try render(), chroma)
    }


    func testGPUPersonGuidanceRequiresSameFrameAndConfidentMask() throws {
        let harness = try MatteHarness(enabled: false)
        let source = UUID()
        let greens: [UInt8] = [0, 0, 0, 0, 0, 0, 109, 109, 102, 255, 255, 255, 255, 255, 255, 255]
        harness.settings.personMatteEnabled = true
        func render(mask: MTLTexture? = nil, maskSource: UUID? = nil, x: Int = 7) throws -> Int {
            try harness.render(sequence: 1, time: 1, source: source, red: 51, green: 109, x: x,
                               greenColumns: greens, personTexture: mask, personSource: maskSource)
        }
        func mask(right: UInt8) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 8, height: 8, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            let texture = try XCTUnwrap(harness.pipeline.device.makeTexture(descriptor: descriptor))
            let bytes: [UInt8] = (0..<64).map { $0 % 8 < 4 ? 255 : right }
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8)
            }
            return texture
        }

        let chroma = try render()
        let confident = try mask(right: 0)
        XCTAssertLessThan(try render(mask: confident), chroma)
        XCTAssertEqual(try render(mask: confident, x: 0), 255)
        XCTAssertEqual(try render(mask: confident, x: 15), 0)
        XCTAssertEqual(try render(mask: confident, maskSource: UUID()), chroma)
        XCTAssertEqual(try render(mask: mask(right: 128)), chroma)
    }


    func testGPUOcclusionOrdersOnlyRegisteredHighConfidenceDepth() throws {
        let harness = try MatteHarness(enabled: false)
        let source = UUID()
        var calibration = CameraCalibration(name: "Test", imageWidth: 16, imageHeight: 16,
                                            fx: 16, fy: 16, cx: 8, cy: 8)
        calibration.source = .measured
        var timeline = PoseTimeline()
        timeline.append(time: 1, transform: calibration.transform, nominal: true)
        harness.settings.camera.calibration = calibration
        harness.settings.poseAlignment = .init(sourceID: source, history: timeline,
                                                stageFromNodeWorld: calibration.transform, maximumAge: 0.15)
        harness.settings.chromaEnabled = false
        harness.settings.depthOcclusionEnabled = true
        harness.recordOcclusion = true
        let stamp: UInt64 = 1_000_000
        func depth(_ meters: Float, confidence: UInt8 = 2, sequence: UInt64 = 1) throws -> DepthPreviewInput {
            var bits = meters.bitPattern.littleEndian
            let sample = withUnsafeBytes(of: &bits) { Data($0) }
            let packet = try CaptureDepthPacket(header: .init(sequence: sequence, captureTimeNanoseconds: stamp,
                width: 2, height: 2, depthEncoding: "depth-float32-le", confidenceEncoding: "confidence-uint8"),
                depth: sample + sample + sample + sample, confidence: Data(repeating: confidence, count: 4))
            return .init(sourceID: source, packet: packet, capturedHostSeconds: 1)
        }
        func render(_ view: CompositeDebugView = .composite, x: Int = 8, y: Int = 8) throws -> Int {
            harness.settings.debugView = view
            return try harness.render(sequence: 1, time: 1, source: source, red: 255, green: 0, x: x, y: y,
                                      arKitCaptureNanoseconds: stamp)
        }

        let cg = try render(.scene)
        XCTAssertNotEqual(cg, 255)
        XCTAssertEqual(try render(), 255)
        XCTAssertEqual(harness.recordedOcclusion?.state, .missingDepth)
        harness.settings.depthPreview = try depth(8)
        XCTAssertEqual(try render(), cg)
        XCTAssertEqual(harness.recordedOcclusion, .init(state: .evaluated, applied: true))
        XCTAssertEqual(try render(x: 0, y: 0), 255) // Clear CG depth is not geometry.
        harness.settings.depthPreview = nil
        XCTAssertEqual(try render(), 255)
        harness.settings.depthPreview = try depth(1)
        XCTAssertEqual(try render(), 255)
        harness.settings.depthPreview = nil
        _ = try render()
        harness.settings.depthPreview = try depth(8, confidence: 1)
        XCTAssertEqual(try render(), 255)
        XCTAssertEqual(harness.recordedOcclusion, .init(state: .evaluated, lowConfidence: true))
        harness.settings.depthPreview = try depth(8, sequence: 2)
        XCTAssertEqual(try render(), 255)
        XCTAssertEqual(harness.recordedOcclusion?.state, .mismatchedDepth)
    }

}

private final class MatteHarness {
    let pipeline: MetalFramePipeline
    let target: MTLTexture
    let metrics = RealtimeMetricsStore()
    var settings = StudioRenderSettings()
    var recordOcclusion = false
    private(set) var recordedOcclusion: TakeDepthOcclusion?
    init(enabled: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        pipeline = try MetalFramePipeline(device: device,pixelFormat: .bgra8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 16,height: 16,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        settings.chromaEnabled = true; settings.temporalMatteEnabled = enabled
        settings.inputEncoding = .linear; settings.debugView = .matte; settings.profile = .reviewCinema
    }
    func render(sequence: UInt64, time: Double, source: UUID, red: UInt8, green: UInt8, x: Int = 0, y: Int = 0, greenColumns: [UInt8]? = nil, greenPixels: [UInt8]? = nil, arKitCaptureNanoseconds: UInt64? = nil,
                personTexture: MTLTexture? = nil, personSource: UUID? = nil) throws -> Int {
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,16,16,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true,kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&optionalBuffer),kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer,[])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<16 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)
            for column in 0..<16 {
                let value = greenPixels?[y * 16 + column] ?? greenColumns?[column] ?? green
                row[column] = UInt32(red) | UInt32(value) << 8 | UInt32(red) << 16 | 0xFF000000
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let captured = CMTime(seconds: time,preferredTimescale: 1_000_000)
        let frame = VideoFrame(identifier: sequence,captureTime: captured,hostReceiveTime: captured,
            colorMetadata: .init(colorPrimaries: nil,transferFunction: nil,yCbCrMatrix: nil),pixelBuffer: buffer,
            quality: .nominal,telemetry: FrameTelemetry(captured: time), arKitCaptureNanoseconds: arKitCaptureNanoseconds)
        var frameSettings = settings
        if let personTexture, let key = PersonMatteMask.FrameKey(frame: frame, source: personSource ?? source) {
            frameSettings.personMatte = PersonMatteMask(key: key, texture: personTexture)
        }
        var auxiliary: TakeAuxiliaryFrame?
        let capture: ((MTLCommandBuffer, MTLTexture, MTLTexture?, MTLFence, TakeAuxiliaryFrame) -> Void)?
        if recordOcclusion {
            capture = { _, _, _, _, frame in auxiliary = frame }
        } else {
            capture = nil
        }
        let command = try pipeline.encode(frame: frame,target: target,settings: frameSettings,metrics: metrics,
                                          now: time+0.02,frameSourceID: source,capture: capture)
        command.commit(); command.waitUntilCompleted()
        auxiliary?.finishDepthOcclusion()
        recordedOcclusion = auxiliary?.depthOcclusion
        XCTAssertEqual(command.status,.completed)
        XCTAssertEqual(metrics.read().protection,.normal)
        var bytes = [UInt8](repeating: 0,count: 16*16*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: 16*4,from: MTLRegionMake2D(0,0,16,16),mipmapLevel: 0) }
        return Int(bytes[(y * 16 + x) * 4])
    }
}
