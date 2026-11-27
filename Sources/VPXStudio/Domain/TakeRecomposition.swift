import CoreGraphics
import CoreMedia
import MetalKit
import VPXCaptureProtocol

struct TakeRecompositionPreview: Sendable {
    struct Frame: Sendable {
        let seconds: Double
        let image: CGImage
    }
    let frames: [Frame]
}

extension TakeReviewService {
    /// Bounded offline preview from the selected frame. Each binary asset is hashed once.
    func recomposePreview(directory: URL, manifest: TakeManifest, startingAt index: Int) throws -> TakeRecompositionPreview {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let rows = try loadFrameIndex(directory: directory, manifest: manifest)
        guard rows.indices.contains(index), let device = MTLCreateSystemDefaultDevice() else {
            throw StudioAssetError.invalid("Recomposition frame or Metal device")
        }
        let config = try restoreCompositeSettings(directory: directory, manifest: manifest)
        let scene = try restoreScene(directory: directory, manifest: manifest, relativePath: "scene.vpx.json")
        guard scene.id == config.sceneID else { throw StudioAssetError.invalid("Take scene mismatch") }
        let firstTime = CMTime(value: rows[index].ptsValue, timescale: rows[index].ptsTimescale)
        var selected: [TakeAuxiliaryTracks.Row] = []
        var budget = 128 * 1024 * 1024
        for row in rows[index...].prefix(60) {
            let elapsed = CMTimeGetSeconds(CMTime(value: row.ptsValue, timescale: row.ptsTimescale) - firstTime)
            guard elapsed < 1, let original = row.originalVideo, let matte = row.matte,
                  original.range.length > 0, matte.length > 0, original.range.length <= budget,
                  matte.length <= budget - original.range.length else { break }
            budget -= original.range.length + matte.length
            selected.append(row)
        }
        guard let first = selected.first, let original = first.originalVideo,
              (1...8192).contains(original.width), (1...8192).contains(original.height),
              let outputWidth = first.matteWidth, let outputHeight = first.matteHeight,
              (1...8192).contains(outputWidth), (1...8192).contains(outputHeight) else {
            throw StudioAssetError.invalid("Take original frame and matte")
        }

        func read(_ ranges: [TakeAuxiliaryTracks.Range], path: String, role: TakeManifest.Asset.Role) throws
            -> (data: Data, start: UInt64)? {
            guard let start = ranges.map(\.offset).min() else { return nil }
            var end = start
            for range in ranges {
                guard range.length > 0 else { throw StudioAssetError.invalid("Take asset range") }
                let upper = range.offset.addingReportingOverflow(UInt64(range.length))
                guard !upper.overflow else { throw StudioAssetError.invalid("Take asset range") }
                end = max(end, upper.partialValue)
            }
            guard end - start <= 128 * 1024 * 1024 else { throw StudioAssetError.invalid("Take preview byte budget") }
            return (try manifest.verifiedAssetData(relativePath: path, role: role, in: directory,
                                                   maximumSize: Int(end - start), byteRange: start..<end), start)
        }
        func slice(_ asset: (data: Data, start: UInt64)?, _ range: TakeAuxiliaryTracks.Range) throws -> Data {
            guard let asset, range.offset >= asset.start, range.offset - asset.start <= UInt64(asset.data.count),
                  range.length > 0 else { throw StudioAssetError.invalid("Take frame range") }
            let offset = Int(range.offset - asset.start)
            guard range.length <= asset.data.count - offset else { throw StudioAssetError.invalid("Take frame range") }
            return asset.data.subdata(in: offset..<(offset + range.length))
        }

        let originals = try read(selected.compactMap { $0.originalVideo?.range }, path: TakeSourceFrame.path, role: .sourceFrames)
        let mattes = try read(selected.compactMap(\.matte), path: "matte.f16le", role: .matte)
        let depthRanges = selected.compactMap(\.depth).flatMap { [$0.values, $0.confidence] }
        let depths = try read(depthRanges, path: "depth.bin", role: .depth)
        let usedLUT = selected.first { $0.lut?.applied == true } != nil
        let lut = usedLUT ? try restoreLUT(directory: directory, manifest: manifest, relativePath: CompositeLUT.takeAssetPath) : nil

        let pipeline = try MetalFramePipeline(device: device, pixelFormat: .bgra8Unorm_srgb)
        let scale = min(1, 640.0 / Double(max(outputWidth, outputHeight)))
        let width = max(1, Int(Double(outputWidth) * scale)), height = max(1, Int(Double(outputHeight) * scale))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, mipmapped: false)
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = .renderTarget
        guard let target = device.makeTexture(descriptor: targetDescriptor) else { throw StudioAssetError.invalid("Take preview target") }
        let metrics = RealtimeMetricsStore()
        let sourceID = UUID()
        var frames: [TakeRecompositionPreview.Frame] = []
        for row in selected {
            try Task.checkCancellation()
            guard let original = row.originalVideo, let matte = row.matte, let mw = row.matteWidth, let mh = row.matteHeight,
                  (1...8192).contains(mw), (1...8192).contains(mh), matte.length == mw * mh * 2 else {
                throw StudioAssetError.invalid("Take matte dimensions")
            }
            let source = try TakeSourceFrame.decode(original, data: slice(originals, original.range))
            let matteBytes = try slice(mattes, matte)
            let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: mw, height: mh, mipmapped: false)
            maskDescriptor.storageMode = .shared
            maskDescriptor.usage = .shaderRead
            guard let mask = device.makeTexture(descriptor: maskDescriptor) else { throw StudioAssetError.invalid("Take matte texture") }
            matteBytes.withUnsafeBytes {
                mask.replace(region: MTLRegionMake2D(0, 0, mw, mh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: mw * 2)
            }

            var settings = StudioRenderSettings()
            settings.scene = scene
            settings.profile = .reviewCinema
            settings.camera.calibration = config.calibration
            try settings.camera.calibration?.validate()
            settings.camera.worldFromCamera = scene.cameraWorldTransform
            settings.camera.setFocalLength(config.focalLengthMillimeters)
            settings.camera.lens.focusDistanceMeters = config.focusDistanceMeters
            settings.camera.lens.radialDistortionK1 = config.radialDistortionK1
            settings.inputEncoding = row.colorConversion?.applied ?? config.inputEncoding
            settings.chromaEnabled = config.chromaEnabled
            settings.depthOcclusionEnabled = config.depthOcclusionEnabled ?? false
            settings.compositeLUT = row.lut?.applied == true ? lut : nil
            let time = CMTime(value: row.ptsValue, timescale: row.ptsTimescale)
            let seconds = CMTimeGetSeconds(time)
            if let pose = row.pose {
                guard pose.worldFromCamera.count == 16 else { throw StudioAssetError.invalid("Take pose") }
                let v = pose.worldFromCamera
                let transform = simd_float4x4(columns: (SIMD4(v[0],v[1],v[2],v[3]), SIMD4(v[4],v[5],v[6],v[7]),
                    SIMD4(v[8],v[9],v[10],v[11]), SIMD4(v[12],v[13],v[14],v[15])))
                try StageRegistration.validateRigid(transform)
                var history = PoseTimeline()
                history.append(time: seconds, transform: transform, nominal: true)
                settings.poseAlignment = .init(sourceID: sourceID, history: history, stageFromNodeWorld: matrix_identity_float4x4, maximumAge: 0.15)
            }
            var stamp: UInt64?
            if row.depthSameARKitFrame == true, let depth = row.depth,
               let sequence = row.inputSequence, sequence == depth.sequence {
                // The row records verified sensor identity; use the playback clock for reconstruction.
                stamp = 1
                let packet = try CaptureDepthPacket(header: .init(sequence: sequence, captureTimeNanoseconds: 1,
                    width: depth.width, height: depth.height, depthEncoding: "depth-float32-le", confidenceEncoding: "confidence-uint8"),
                    depth: slice(depths, depth.values), confidence: slice(depths, depth.confidence))
                settings.depthPreview = .init(sourceID: sourceID, packet: packet, capturedHostSeconds: seconds)
            }
            let frame = VideoFrame(identifier: row.inputSequence ?? UInt64(row.frameIndex), captureTime: time,
                hostReceiveTime: time, colorMetadata: source.color, pixelBuffer: source.buffer, quality: .nominal,
                telemetry: .init(captured: seconds), arKitCaptureNanoseconds: stamp)
            let command = try pipeline.encode(frame: frame, target: target, settings: settings, metrics: metrics,
                                              now: seconds, frameSourceID: sourceID, savedMatte: mask)
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed, metrics.read().protection == .normal else {
                throw StudioAssetError.invalid("Take recomposition render")
            }
            var bytes = Data(count: width * height * 4)
            bytes.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw StudioAssetError.invalid("Take preview image")
            }
            frames.append(.init(seconds: CMTimeGetSeconds(time - firstTime), image: image))
        }
        return .init(frames: frames)
    }
}
