import XCTest
import CoreVideo
import CoreMedia
import MetalKit
import simd
@testable import VPXStudio

final class PhaseOneTests: XCTestCase {
    func testReferenceChangeRequiresExplicitReset() {
        var state = TrackingReferenceState()
        state.observe(1); XCTAssertFalse(state.requiresReset)
        state.observe(2); XCTAssertTrue(state.requiresReset)
        state.observe(2); XCTAssertTrue(state.requiresReset)
        state.reset(); state.observe(2); XCTAssertFalse(state.requiresReset)
        state.observe(3); XCTAssertTrue(state.requiresReset)
    }
    func testCalibrationProjectionBreathingAndInvalidProfiles() throws {
        var calibration = CameraCalibration(name: "Measured",imageWidth: 1920,imageHeight: 1080,fx: 1200,fy: 1100,cx: 960,cy: 540)
        calibration.source = .measured
        calibration.k2 = 0.01; calibration.p1 = 0.001
        calibration.breathing = [.init(focusMeters: 1,focalLengthMillimeters: 35),.init(focusMeters: 3,focalLengthMillimeters: 40)]
        try calibration.validate()
        XCTAssertEqual(calibration.focalLength(at: 2,fallback: 35),37.5)
        var rig = CameraRig.preview
        rig.calibration = calibration; rig.lens.focusDistanceMeters = 2
        XCTAssertEqual(rig.projection(aspectRatio: 16/9).columns.0.x,2*1200/1920*(37.5/35),accuracy: 0.0001)
        calibration.fx = 0
        XCTAssertThrowsError(try calibration.validate())
        calibration.fx = 1200; calibration.worldFromCamera = [0]
        XCTAssertThrowsError(try calibration.validate())
    }

    private func fixture(indices: [UInt16] = [0,1,2], mode: Int = 4) throws -> Data {
        let positions: [Float] = [-1,-1,0, 1,-1,0, 0,1,0]
        var bytes = positions.withUnsafeBytes { Data($0) }
        bytes.append(indices.withUnsafeBytes { Data($0) })
        let json: [String:Any] = ["asset":["version":"2.0"],"buffers":[["uri":"data:application/octet-stream;base64,"+bytes.base64EncodedString(),"byteLength":bytes.count]],
            "bufferViews":[["buffer":0,"byteLength":36],["buffer":0,"byteOffset":36,"byteLength":6]],
            "accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3"],["bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"]],
            "materials":[["pbrMetallicRoughness":["baseColorFactor":[0.8,0.2,0.1,1],"metallicFactor":0.4,"roughnessFactor":0.3]]],
            "meshes":[["primitives":[["attributes":["POSITION":0],"indices":1,"material":0,"mode":mode]]]],
            "nodes":[["mesh":0,"translation":[0,0,-4]]],"scenes":[["nodes":[0]]],"scene":0]
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testGLTFStaticMeshPBRTransformAndBounds() throws {
        let root = FileManager.default.temporaryDirectory
        let scene = try GLTFSceneLoader.load(data: fixture(),baseDirectory: root)
        XCTAssertEqual(scene.meshes.count,1)
        XCTAssertEqual(scene.meshes[0].vertices.count,3)
        XCTAssertEqual(scene.meshes[0].vertices[0].position.z,-4)
        XCTAssertEqual(scene.meshes[0].vertices[0].normal.z,1)
        XCTAssertEqual(scene.meshes[0].material.metallic,0.4)
        XCTAssertThrowsError(try GLTFSceneLoader.load(data: fixture(indices: [0,1,5]),baseDirectory: root))
        XCTAssertThrowsError(try GLTFSceneLoader.load(data: fixture(mode: 5),baseDirectory: root))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String:Any])
        document["nodes"] = [["children":[0]]]
        XCTAssertThrowsError(try GLTFSceneLoader.load(data: JSONSerialization.data(withJSONObject: document),baseDirectory: root))
        document["nodes"] = [["mesh":0]]
        document["buffers"] = [["uri":"../outside.bin","byteLength":42]]
        XCTAssertThrowsError(try GLTFSceneLoader.load(data: JSONSerialization.data(withJSONObject: document),baseDirectory: root))
    }

    func testPolicyMetadataTimeoutAndGPUHysteresis() {
        XCTAssertNil(SDRInputEncoding.automatic.resolved(for: .init(colorPrimaries: nil,transferFunction: nil,yCbCrMatrix: nil)))
        XCTAssertEqual(SDRInputEncoding.sRGB.resolved(for: .init(colorPrimaries: nil,transferFunction: nil,yCbCrMatrix: nil)),.sRGB)
        XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: 0.3,timeoutSeconds: LiveQualityProfile.liveQuality.inputTimeoutSeconds),.stale)
        XCTAssertEqual(VideoInputHealth.evaluate(ageSeconds: 0.01,captureAgeSeconds: 1),.stale)
        var monitor = GPUDeadlineMonitor()
        for _ in 0..<3 { monitor.record(milliseconds: 20,budget: 16) }
        XCTAssertTrue(monitor.isProtected)
        for _ in 0..<9 { monitor.record(milliseconds: 2,budget: 16) }
        XCTAssertTrue(monitor.isProtected)
        monitor.record(milliseconds: 2,budget: 16)
        XCTAssertFalse(monitor.isProtected)
        let metrics = RealtimeMetricsStore()
        metrics.recordFrameSubmitted(at: 1,inputFrame: nil,expectedFramesPerSecond: 15)
        metrics.recordFrameSubmitted(at: 1+1/15,inputFrame: nil,expectedFramesPerSecond: 15)
        XCTAssertEqual(metrics.read().droppedFrameEstimate,0)
    }

    private func image(color: UInt32, yuvTenBit: Bool? = nil, fullRange: Bool = false) throws -> VideoFrame {
        var pixel: CVPixelBuffer?
        let format = yuvTenBit.map { ten in
            ten ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) :
                (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        } ?? kCVPixelFormatType_32BGRA
        XCTAssertEqual(CVPixelBufferCreate(nil,8,8,format,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel),kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer,[])
        if let ten = yuvTenBit {
            for plane in 0..<2 {
                let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,plane))
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)
                for y in 0..<CVPixelBufferGetHeightOfPlane(buffer,plane) {
                    if ten { pointer.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self).initialize(repeating: UInt16(512<<6),count: stride/2) }
                    else { pointer.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self).initialize(repeating: 128,count: stride) }
                }
            }
        } else {
            let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<8 { pointer.advanced(by: y*stride).assumingMemoryBound(to: UInt32.self).initialize(repeating: color,count: 8) }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return VideoFrame(identifier: 1,captureTime: now,hostReceiveTime: now,
            colorMetadata: .init(colorPrimaries: "ITU_R_709_2",transferFunction: yuvTenBit == nil ? "sRGB" : "ITU_R_709_2",yCbCrMatrix: "ITU_R_709_2"),pixelBuffer: buffer,quality: .nominal)
    }

    private func render(_ frame: VideoFrame?, settings: StudioRenderSettings = StudioRenderSettings()) throws -> ([UInt8],RealtimeMetricsSnapshot) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let pipeline = try MetalFramePipeline(device: device,pixelFormat: .bgra8Unorm_srgb)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 32,height: 32,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor)), metrics = RealtimeMetricsStore()
        let command = try pipeline.encode(frame: frame,target: target,settings: settings,metrics: metrics,
            now: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "")
        var bytes = [UInt8](repeating: 0,count: 32*32*4)
        target.getBytes(&bytes,bytesPerRow: 32*4,from: MTLRegionMake2D(0,0,32,32),mipmapLevel: 0)
        return (Array(bytes[(16*32+16)*4..<(16*32+16)*4+4]),metrics.read())
    }

    func testGPUCompositeSRGBDoesNotDoubleEncodeAndMatteKeysGreen() throws {
        let gray = try render(image(color: 0xFF808080))
        XCTAssertEqual(gray.1.protection,.normal)
        XCTAssertEqual(Int(gray.0[0]),128,accuracy: 2)
        var settings = StudioRenderSettings()
        settings.chromaEnabled = true; settings.debugView = .matte
        let matte = try render(image(color: 0xFF00FF00),settings: settings)
        XCTAssertEqual(matte.0[0],0)
        settings.chromaEnabled = false
        let opaque = try render(image(color: 0xFF00FF00),settings: settings)
        XCTAssertEqual(opaque.0[0],255)
    }

    func testGPUYUV8And10BitShareLimitedRangeConversion() throws {
        let eight = try render(image(color: 0,yuvTenBit: false))
        let ten = try render(image(color: 0,yuvTenBit: true))
        XCTAssertEqual(eight.1.protection,.normal); XCTAssertEqual(ten.1.protection,.normal)
        XCTAssertEqual(Int(eight.0[0]),Int(ten.0[0]),accuracy: 2)
        XCTAssertGreaterThan(eight.0[0],130); XCTAssertLessThan(eight.0[0],155)
        let full8 = try render(image(color: 0,yuvTenBit: false,fullRange: true))
        let full10 = try render(image(color: 0,yuvTenBit: true,fullRange: true))
        XCTAssertEqual(full8.1.protection,.normal); XCTAssertEqual(full10.1.protection,.normal)
        XCTAssertEqual(Int(full8.0[0]),Int(full10.0[0]),accuracy: 2)
    }

    func testUnknownColorRequiresExplicitOverrideAndFormatBudgetsAreRecorded() throws {
        let original = try image(color: 0xFF808080)
        let frame = VideoFrame(identifier: 1,captureTime: original.captureTime,hostReceiveTime: original.hostReceiveTime,
            colorMetadata: .init(colorPrimaries: nil,transferFunction: nil,yCbCrMatrix: nil),pixelBuffer: original.pixelBuffer,quality: .nominal)
        XCTAssertEqual(try render(frame).1.protection,.unknownColor)
        var settings = StudioRenderSettings(); settings.inputEncoding = .sRGB
        XCTAssertEqual(try render(frame,settings: settings).1.protection,.normal)
        let metrics = RealtimeMetricsStore()
        metrics.recordFormatImport(format: "BGRA",milliseconds: 3,budget: 2)
        metrics.recordFormatConversion(format: "BGRA",start: 1,end: 1.006,budget: 4)
        XCTAssertEqual(metrics.read().inputFormats["BGRA"]?.importBudgetMisses,1)
        XCTAssertEqual(metrics.read().inputFormats["BGRA"]?.conversionBudgetMisses,1)
    }

    func testExampleAssetsAreLoadable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(try GLTFSceneLoader.load(root.appendingPathComponent("Examples/Phase1/CubeAndFloor.gltf")).meshes.count,2)
        XCTAssertEqual(try CameraCalibration.load(root.appendingPathComponent("Examples/Phase1/CameraCalibration.json")).source,.estimated)
    }

    func testGPUSafetyAndPBRSceneRender() throws {
        var settings = StudioRenderSettings(); settings.trackingLost = true
        let protected = try render(image(color: 0xFFFFFFFF),settings: settings)
        XCTAssertEqual(protected.1.protection,.trackingLost)
        XCTAssertLessThan(protected.0[0],40)
        settings.trackingLost = false
        let scene = try render(nil,settings: settings)
        XCTAssertEqual(scene.1.protection,.inputLost)
        XCTAssertEqual(scene.0[3],255)
        settings.scene = try GLTFSceneLoader.load(data: fixture(),baseDirectory: FileManager.default.temporaryDirectory)
        let lit = try render(nil,settings: settings)
        XCTAssertGreaterThan(lit.0[2],lit.0[0])
        settings.scene.lightIntensity = 0
        let dark = try render(nil,settings: settings)
        XCTAssertGreaterThan(lit.0[2],dark.0[2])
    }
}
