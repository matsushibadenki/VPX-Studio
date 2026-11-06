import MetalKit
import CoreMedia

struct StudioRenderSettings: Sendable {
    var scene = StudioScene.demo
    var camera = CameraRig.preview
    var inputEncoding = SDRInputEncoding.automatic
    var debugView = CompositeDebugView.composite
    var profile = LiveQualityProfile.liveFast
    var chromaEnabled = false
    var greenThreshold: Float = 0.12
    var greenSoftness: Float = 0.2
    var temporalMatteEnabled = false
    var temporalMatteStrength: Float = 0.5
    var trackingLost = false
    var protectMissingInput = false
    var poseAlignment: PoseCameraAlignment?
    var requirePoseAlignment = false
    var depthPreview: DepthPreviewInput?
    var depthPreviewFarMeters: Float = 10
}

private struct VideoParameters {
    var distortion: SIMD4<Float>
    var intrinsics: SIMD4<Float>
    var options: SIMD4<Float>
    var range: SIMD4<Float>
    var matrix: SIMD4<Float>
}
private struct SceneParameters {
    var viewProjection: simd_float4x4
    var lightProjection: simd_float4x4
    var camera: SIMD4<Float>
    var lightDirection: SIMD4<Float>
    var radiance: SIMD4<Float>
}
private struct MaterialParameters { var baseColor: SIMD4<Float>; var factors: SIMD4<Float> }
private struct GPUMesh { let buffer: MTLBuffer; let count: Int; let material: SceneMaterial }

/// Resources are immutable once submitted and retained until the command buffer completes.
private final class ImportedVideo: @unchecked Sendable {
    let frame: VideoFrame
    var wrappers: [CVMetalTexture] = []
    var textures: [MTLTexture] = []
    var isYUV = false
    var isTenBit = false
    var isFullRange = false
    init(frame: VideoFrame) { self.frame = frame }
}

/// GPU timing values are read only after both buffers on this queue have completed.
private final class ConversionTiming: @unchecked Sendable {
    let buffer: MTLCommandBuffer
    init(_ buffer: MTLCommandBuffer) { self.buffer = buffer }
}

final class MetalFramePipeline {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let normalize: MTLComputePipelineState
    private let mattePipeline: MTLComputePipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let conversionEvent: MTLSharedEvent
    private var conversionSerial: UInt64 = 0
    private let matteFence: MTLFence
    private let shadowFence: MTLFence
    private let sceneFence: MTLFence
    private let textureCache: CVMetalTextureCache
    private let fallback: MTLTexture
    private let depthConfidenceFallback: MTLTexture
    private var sceneTexture: MTLTexture?
    private var sceneDepth: MTLTexture?
    private var videoTexture: MTLTexture?
    private var matteTexture: MTLTexture?
    private var historyVideoTexture: MTLTexture?
    private var historyMatteTexture: MTLTexture?
    private var matteHistoryPolicy = TemporalMattePolicy()
    private lazy var depthPreviewCache = DepthPreviewTextureCache(device: device)
    private var shadowTexture: MTLTexture?
    private var meshes: [GPUMesh] = []
    private var sceneID: UUID?
    private var sceneCenter = SIMD3<Float>(0,0,-4)
    private var sceneRadius: Float = 5
    let frameGraph = FrameGraph()

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(), let event = device.makeSharedEvent(), let mf = device.makeFence(),
              let sf = device.makeFence(), let cf = device.makeFence() else { throw StudioAssetError.invalid("Metal queue/fence") }
        self.queue = queue; conversionEvent = event; matteFence = mf; shadowFence = sf; sceneFence = cf
        guard let url = Bundle.module.url(forResource: "StudioPipeline", withExtension: "metal") else { throw StudioAssetError.invalid("shader resource") }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        guard let nf = library.makeFunction(name: "normalizeCamera"), let af = library.makeFunction(name: "buildMatte") else { throw StudioAssetError.invalid("compute functions") }
        normalize = try device.makeComputePipelineState(function: nf)
        mattePipeline = try device.makeComputePipelineState(function: af)
        let mesh = MTLRenderPipelineDescriptor()
        mesh.vertexFunction = library.makeFunction(name: "studioMeshVertex")
        mesh.fragmentFunction = library.makeFunction(name: "studioPBR")
        mesh.colorAttachments[0].pixelFormat = .rgba16Float
        mesh.depthAttachmentPixelFormat = .depth32Float
        meshPipeline = try device.makeRenderPipelineState(descriptor: mesh)
        let shadow = MTLRenderPipelineDescriptor()
        shadow.vertexFunction = library.makeFunction(name: "studioShadowVertex")
        shadow.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: shadow)
        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = library.makeFunction(name: "studioQuad")
        composite.fragmentFunction = library.makeFunction(name: "studioComposite")
        composite.colorAttachments[0].pixelFormat = pixelFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual; depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else { throw StudioAssetError.invalid("depth state") }
        depthState = state
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache) == kCVReturnSuccess, let cache else { throw StudioAssetError.invalid("texture cache") }
        textureCache = cache
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw StudioAssetError.invalid("fallback texture") }
        fallback = texture
        let confidenceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint,width: 1,height: 1,mipmapped: false)
        confidenceDescriptor.storageMode = .shared; confidenceDescriptor.usage = [.shaderRead]
        guard let confidenceFallback = device.makeTexture(descriptor: confidenceDescriptor) else { throw StudioAssetError.invalid("depth confidence fallback") }
        depthConfidenceFallback = confidenceFallback
        var zeroConfidence: UInt8 = 0
        confidenceFallback.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &zeroConfidence,bytesPerRow: 1)
        var zero: UInt32 = 0
        texture.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        for pass in [FramePass(name: "normalize", dependsOn: []), FramePass(name: "matte", dependsOn: ["normalize"]),
                     FramePass(name: "shadow", dependsOn: []), FramePass(name: "scene", dependsOn: ["shadow"]),
                     FramePass(name: "composite", dependsOn: ["scene","matte"]),
                     FramePass(name: "matteHistory", dependsOn: ["composite"])] { try frameGraph.register(pass) }
        _ = try frameGraph.orderedPasses()
    }

    private func texture(_ format: MTLPixelFormat, width: Int, height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = usage
        guard let result = device.makeTexture(descriptor: d) else { throw StudioAssetError.invalid("render texture allocation") }
        return result
    }

    private func prepare(width: Int, height: Int, scene: StudioScene) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw StudioAssetError.invalid("render size") }
        if sceneTexture?.width != width || sceneTexture?.height != height {
            let scene = try texture(.rgba16Float, width: width, height: height, usage: [.renderTarget,.shaderRead])
            let depth = try texture(.depth32Float, width: width, height: height, usage: [.renderTarget])
            let video = try texture(.rgba16Float, width: width, height: height, usage: [.shaderRead,.shaderWrite])
            let matte = try texture(.r16Float, width: width, height: height, usage: [.shaderRead,.shaderWrite])
            let shadow = try texture(.depth32Float, width: 1024, height: 1024, usage: [.renderTarget,.shaderRead])
            sceneTexture = scene; sceneDepth = depth; videoTexture = video; matteTexture = matte; shadowTexture = shadow
        }
        if sceneID != scene.id {
            let uploaded = try scene.meshes.map { mesh -> GPUMesh in
                guard !mesh.vertices.isEmpty, let buffer = mesh.vertices.withUnsafeBytes({ bytes in
                    device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                }) else { throw StudioAssetError.invalid("mesh upload") }
                return GPUMesh(buffer: buffer, count: mesh.vertices.count, material: mesh.material)
            }
            meshes = uploaded; sceneID = scene.id
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for mesh in scene.meshes { for v in mesh.vertices { lo = simd_min(lo,v.position.xyz); hi = simd_max(hi,v.position.xyz) } }
            if !scene.meshes.isEmpty { sceneCenter = (lo+hi)/2; sceneRadius = max(1,simd_length(hi-lo)/2) }
        }
    }

    private func importVideo(_ frame: VideoFrame) -> ImportedVideo? {
        let buffer = frame.pixelBuffer, format = CVPixelBufferGetPixelFormatType(buffer)
        let result = ImportedVideo(frame: frame)
        let formats: [MTLPixelFormat]
        switch format {
        case kCVPixelFormatType_32BGRA: formats = [.bgra8Unorm]
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            formats = [.r8Unorm,.rg8Unorm]; result.isYUV = true
            result.isFullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            formats = [.r16Unorm,.rg16Unorm]; result.isYUV = true; result.isTenBit = true
            result.isFullRange = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        default: return nil
        }
        for (plane, metalFormat) in formats.enumerated() {
            var wrapper: CVMetalTexture?
            let w = result.isYUV ? CVPixelBufferGetWidthOfPlane(buffer,plane) : CVPixelBufferGetWidth(buffer)
            let h = result.isYUV ? CVPixelBufferGetHeightOfPlane(buffer,plane) : CVPixelBufferGetHeight(buffer)
            guard CVMetalTextureCacheCreateTextureFromImage(nil,textureCache,buffer,nil,metalFormat,w,h,plane,&wrapper) == kCVReturnSuccess,
                  let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else { return nil }
            result.wrappers.append(wrapper); result.textures.append(texture)
        }
        return result
    }

    /// Returns an uncommitted final command buffer. The caller may attach a drawable before commit.
    func encode(frame: VideoFrame?, target: MTLTexture, settings inputSettings: StudioRenderSettings,
                metrics: RealtimeMetricsStore, now: Double, frameSourceID: UUID? = nil) throws -> MTLCommandBuffer {
        var resolvedSettings = inputSettings
        let aligned = inputSettings.poseAlignment.flatMap { alignment in
            alignment.sourceID == frameSourceID ? alignment.resolve(videoCaptureTime: frame?.telemetry.captured,now: now) : nil
        }
        let unaligned = inputSettings.requirePoseAlignment && aligned == nil
        if let aligned {
            resolvedSettings.camera.worldFromCamera = aligned.transform
            if var calibration = resolvedSettings.camera.calibration {
                calibration.worldFromCamera = (0..<4).flatMap { [aligned.transform[$0].x,aligned.transform[$0].y,aligned.transform[$0].z,aligned.transform[$0].w] }
                resolvedSettings.camera.calibration = calibration
            }
        }
        let settings = resolvedSettings
        let debugView = settings.protectMissingInput ? CompositeDebugView.composite : settings.debugView
        let showDepth = debugView == .depth || debugView == .depthConfidence
        let depthTextures: DepthPreviewTextureCache.Textures?
        if showDepth {
            depthTextures = try depthPreviewCache.textures(for: settings.depthPreview,sourceID: frameSourceID,now: now)
        } else { depthPreviewCache.clear(); depthTextures = nil }
        if showDepth {
            let input = settings.depthPreview.flatMap { $0.sourceID == frameSourceID ? $0 : nil }
            metrics.recordDepthPreview(DepthPreviewTelemetry(available: depthTextures != nil,
                width: input.map { Int($0.packet.header.width) },height: input.map { Int($0.packet.header.height) },
                ageMilliseconds: input.flatMap { $0.capturedHostSeconds.isFinite && now.isFinite ? (now-$0.capturedHostSeconds)*1000 : nil }))
        } else { metrics.recordDepthPreview(nil) }
        let alignmentTelemetry = settings.poseAlignment.map { alignment in
            PoseAlignmentTelemetry(mode: aligned.flatMap { .init(rawValue: $0.mode.rawValue) } ?? .unavailable,
                horizonMilliseconds: aligned?.horizonMilliseconds,
                predictionErrorMeters: alignment.history.predictionErrorMeters,
                predictionErrorRadians: alignment.history.predictionErrorRadians,
                predictionErrorHorizonMilliseconds: alignment.history.predictionErrorHorizonMilliseconds)
        }
        metrics.recordPoseAlignment(alignmentTelemetry ?? (settings.requirePoseAlignment
            ? PoseAlignmentTelemetry(mode: .unavailable,horizonMilliseconds: nil,predictionErrorMeters: nil,
                predictionErrorRadians: nil,predictionErrorHorizonMilliseconds: nil) : nil))
        try prepare(width: target.width, height: target.height, scene: settings.scene)
        let wantsMatteHistory = settings.temporalMatteEnabled && settings.chromaEnabled &&
            settings.temporalMatteStrength > 0 && settings.temporalMatteStrength <= 0.8
        if wantsMatteHistory {
            if historyVideoTexture?.width != target.width || historyVideoTexture?.height != target.height {
                let video = try texture(.rgba16Float,width: target.width,height: target.height,usage: [.shaderRead])
                let matte = try texture(.r16Float,width: target.width,height: target.height,usage: [.shaderRead])
                historyVideoTexture = video; historyMatteTexture = matte
                matteHistoryPolicy.reset()
            }
        } else {
            historyVideoTexture = nil; historyMatteTexture = nil; matteHistoryPolicy.reset()
        }
        guard let sceneTexture, let sceneDepth, let videoTexture, let matteTexture, let shadowTexture,
              let conversion = queue.makeCommandBuffer(), let command = queue.makeCommandBuffer() else { throw StudioAssetError.invalid("frame resources") }
        let age = frame.map { now - CMTimeGetSeconds($0.hostReceiveTime) }
        let active = VideoInputHealth.evaluate(ageSeconds: age, qualityLost: frame?.quality == .lost,
                                               timeoutSeconds: settings.profile.inputTimeoutSeconds,
                                               captureAgeSeconds: frame?.telemetry.captured.map { now-$0 }) == .active
        let importStart = CACurrentMediaTime()
        let imported = active ? frame.flatMap(importVideo) : nil
        let encoding = frame.flatMap { settings.inputEncoding.resolved(for: $0.colorMetadata) }
        let gpuProtected = metrics.read().gpuProtected
        let protection: OutputProtection = gpuProtected ? .gpuOverload : settings.trackingLost ? .trackingLost :
            !active ? .inputLost : unaligned ? .poseUnaligned : imported == nil ? .unsupportedFormat : encoding == nil ? .unknownColor : .normal
        metrics.recordProtection(protection)
        let hasVideo = protection == .normal
        let format = frame.map { String(CVPixelBufferGetPixelFormatType($0.pixelBuffer), radix: 16) } ?? "none"
        if let frame, imported != nil {
            metrics.recordInput(frame, renderTime: now, importMilliseconds: (CACurrentMediaTime()-importStart)*1000)
            metrics.recordFormatImport(format: format, milliseconds: (CACurrentMediaTime()-importStart)*1000,
                                       budget: settings.profile.textureImportBudgetMilliseconds)
        }
        let c = settings.camera.calibration
        var videoParams = VideoParameters(distortion: SIMD4(c?.k1 ?? settings.camera.lens.radialDistortionK1,c?.k2 ?? 0,c?.k3 ?? 0,c?.p1 ?? 0),
            intrinsics: SIMD4((c?.cx ?? 0.5)/(c?.imageWidth ?? 1),(c?.cy ?? 0.5)/(c?.imageHeight ?? 1),
                              (c?.fx ?? 1)/(c?.imageWidth ?? 1),(c?.fy ?? 1)/(c?.imageHeight ?? 1)),
            options: SIMD4(c?.p2 ?? 0,Float(encoding?.shaderCode ?? 3),hasVideo ? 1 : 0,imported?.isYUV == true ? 1 : 0),
            range: SIMD4(0,1,0.5,1), matrix: SIMD4(0.2126,0.0722,1,0))
        if let imported, imported.isYUV {
            let maximum: Float = imported.isTenBit ? 1023 : 255
            let multiplier: Float = imported.isTenBit ? 4 : 1
            videoParams.range = imported.isFullRange ? SIMD4(0,1,128*multiplier/maximum,1) :
                SIMD4(16*multiplier/maximum,maximum/(219*multiplier),128*multiplier/maximum,maximum/(224*multiplier))
            videoParams.matrix.z = imported.isTenBit ? 65535/(64*1023) : 1
            if frame?.colorMetadata.yCbCrMatrix == "ITU_R_601_4" { videoParams.matrix.x = 0.299; videoParams.matrix.y = 0.114 }
            if frame?.colorMetadata.yCbCrMatrix == "ITU_R_2020" { videoParams.matrix.x = 0.2627; videoParams.matrix.y = 0.0593 }
        }
        let normalization = [videoParams.distortion,videoParams.intrinsics,videoParams.options,videoParams.range,videoParams.matrix]
            .flatMap { [$0.x,$0.y,$0.z,$0.w] } + [settings.greenThreshold,settings.greenSoftness,settings.temporalMatteStrength,
                Float(frame.map { CVPixelBufferGetWidth($0.pixelBuffer) } ?? 0),Float(frame.map { CVPixelBufferGetHeight($0.pixelBuffer) } ?? 0)]
        let historyKey = frameSourceID.map { TemporalMattePolicy.Key(sourceID: $0,width: target.width,height: target.height,
            pixelFormat: frame.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) } ?? 0,normalization: normalization,
            quality: frame?.quality ?? .lost) }
        var nextMattePolicy = matteHistoryPolicy
        let historyMode = nextMattePolicy.next(key: historyKey,sequence: frame?.identifier,captureTime: frame?.telemetry.captured,
            enabled: wantsMatteHistory && hasVideo)
        metrics.recordTemporalMatte(historyMode)
        guard let normalizeEncoder = conversion.makeComputeCommandEncoder() else { throw StudioAssetError.invalid("normalize encoder") }
        normalizeEncoder.label = "Normalize + lens undistort + SDR decode"
        normalizeEncoder.setComputePipelineState(normalize)
        normalizeEncoder.setTexture(imported?.textures.first ?? fallback,index: 0)
        normalizeEncoder.setTexture(imported?.textures.last ?? fallback,index: 1)
        normalizeEncoder.setTexture(videoTexture,index: 2)
        normalizeEncoder.setBytes(&videoParams,length: MemoryLayout<VideoParameters>.stride,index: 0)
        dispatch(normalizeEncoder, pipeline: normalize, width: target.width, height: target.height)
        normalizeEncoder.endEncoding()
        conversionSerial &+= 1
        conversion.encodeSignalEvent(conversionEvent,value: conversionSerial)
        command.encodeWaitForEvent(conversionEvent,value: conversionSerial)
        let conversionBudget = settings.profile.conversionBudgetMilliseconds
        conversion.addCompletedHandler { completed in
            if imported != nil { metrics.recordFormatConversion(format: format, start: completed.gpuStartTime, end: completed.gpuEndTime, budget: conversionBudget) }
            _ = imported // Keep CVMetalTexture and CVPixelBuffer alive through conversion.
        }
        conversion.commit()

        let direction = simd_normalize(settings.scene.lightDirection)
        let lightView = Self.lookAt(eye: sceneCenter+direction*(sceneRadius*2+1), target: sceneCenter)
        let radius = sceneRadius*1.3
        let near: Float = 0.01, far = sceneRadius*5+5
        let ortho = simd_float4x4(columns: (SIMD4(1/radius,0,0,0),SIMD4(0,1/radius,0,0),SIMD4(0,0,1/(near-far),0),SIMD4(0,0,near/(near-far),1)))
        let cameraWorld = c?.transform ?? settings.camera.worldFromCamera
        var sceneParams = SceneParameters(viewProjection: settings.camera.projection(aspectRatio: Float(target.width)/Float(target.height))*simd_inverse(cameraWorld),
            lightProjection: ortho*lightView, camera: cameraWorld.columns.3, lightDirection: SIMD4(direction,0),
            radiance: SIMD4(settings.scene.lightColor*settings.scene.lightIntensity,1))
        let blockOutput = protection != .normal && protection != .inputLost || protection == .inputLost && settings.protectMissingInput
        for pass in try frameGraph.orderedPasses() {
            switch pass.name {
            case "shadow":
                let d = MTLRenderPassDescriptor()
                d.depthAttachment.texture = shadowTexture; d.depthAttachment.loadAction = .clear
                d.depthAttachment.storeAction = .store; d.depthAttachment.clearDepth = 1
                guard let e = command.makeRenderCommandEncoder(descriptor: d) else { throw StudioAssetError.invalid("shadow encoder") }
                e.label = "Directional shadow map"
                e.setRenderPipelineState(shadowPipeline); e.setDepthStencilState(depthState)
                e.setFrontFacing(.counterClockwise); e.setCullMode(.back)
                e.setDepthBias(0.001,slopeScale: 1,clamp: 0.01)
                e.setVertexBytes(&sceneParams,length: MemoryLayout<SceneParameters>.stride,index: 1)
                if !blockOutput { for mesh in meshes { e.setVertexBuffer(mesh.buffer,offset: 0,index: 0); e.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: mesh.count) } }
                e.updateFence(shadowFence,after: .fragment); e.endEncoding()
            case "scene":
                let d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = sceneTexture; d.colorAttachments[0].loadAction = .clear
                d.colorAttachments[0].storeAction = .store; d.colorAttachments[0].clearColor = MTLClearColor(red: 0.015,green: 0.02,blue: 0.04,alpha: 1)
                d.depthAttachment.texture = sceneDepth; d.depthAttachment.loadAction = .clear; d.depthAttachment.storeAction = .dontCare; d.depthAttachment.clearDepth = 1
                guard let e = command.makeRenderCommandEncoder(descriptor: d) else { throw StudioAssetError.invalid("scene encoder") }
                e.label = "Scene-linear PBR"
                e.waitForFence(shadowFence,before: .fragment)
                e.setRenderPipelineState(meshPipeline); e.setDepthStencilState(depthState)
                e.setFrontFacing(.counterClockwise); e.setCullMode(.back)
                e.setVertexBytes(&sceneParams,length: MemoryLayout<SceneParameters>.stride,index: 1)
                e.setFragmentBytes(&sceneParams,length: MemoryLayout<SceneParameters>.stride,index: 0)
                e.setFragmentTexture(shadowTexture,index: 0)
                if !blockOutput { for mesh in meshes {
                    var material = MaterialParameters(baseColor: mesh.material.baseColor,factors: SIMD4(mesh.material.metallic,mesh.material.roughness,0,0))
                    e.setFragmentBytes(&material,length: MemoryLayout<MaterialParameters>.stride,index: 1)
                    e.setVertexBuffer(mesh.buffer,offset: 0,index: 0); e.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: mesh.count)
                } }
                e.updateFence(sceneFence,after: .fragment); e.endEncoding()
            case "matte":
                guard let e = command.makeComputeCommandEncoder() else { throw StudioAssetError.invalid("matte encoder") }
                e.label = "Explicit alpha matte"
                e.setComputePipelineState(mattePipeline)
                e.setTexture(videoTexture,index: 0); e.setTexture(matteTexture,index: 1)
                e.setTexture(historyVideoTexture ?? fallback,index: 2)
                e.setTexture(historyMatteTexture ?? fallback,index: 3)
                var key = SIMD4<Float>(settings.chromaEnabled ? 1 : 0,settings.greenThreshold,settings.greenSoftness,0)
                e.setBytes(&key,length: MemoryLayout<SIMD4<Float>>.stride,index: 0)
                var temporal = SIMD4<Float>(settings.temporalMatteStrength,0.08,0.25,
                    historyMode == .reuse ? 2 : historyMode == .blend ? 1 : 0)
                e.setBytes(&temporal,length: MemoryLayout<SIMD4<Float>>.stride,index: 1)
                dispatch(e,pipeline: mattePipeline,width: target.width,height: target.height)
                e.updateFence(matteFence); e.endEncoding()
            case "composite":
                let d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = target; d.colorAttachments[0].loadAction = .dontCare; d.colorAttachments[0].storeAction = .store
                guard let e = command.makeRenderCommandEncoder(descriptor: d) else { throw StudioAssetError.invalid("composite encoder") }
                e.label = "Linear composite to SDR output"
                e.waitForFence(sceneFence,before: .fragment); e.waitForFence(matteFence,before: .fragment)
                e.setRenderPipelineState(compositePipeline)
                e.setFragmentTexture(sceneTexture,index: 0); e.setFragmentTexture(videoTexture,index: 1); e.setFragmentTexture(matteTexture,index: 2)
                e.setFragmentTexture(depthTextures?.depth ?? fallback,index: 3)
                // Integer textures require a matching integer fallback.
                e.setFragmentTexture(depthTextures?.confidence ?? depthConfidenceFallback,index: 4)
                let mode = CompositeDebugView.allCases.firstIndex(of: debugView) ?? 0
                var options = SIMD4<Float>(Float(mode),blockOutput ? 1 : 0,settings.chromaEnabled ? 1 : 0,depthTextures == nil ? 0 : 1)
                e.setFragmentBytes(&options,length: MemoryLayout<SIMD4<Float>>.stride,index: 0)
                var depthParameters = SIMD4<Float>(settings.depthPreviewFarMeters.isFinite ? max(0.5,min(20,settings.depthPreviewFarMeters)) : 10,
                    Float(target.width)/Float(target.height),0,0)
                e.setFragmentBytes(&depthParameters,length: MemoryLayout<SIMD4<Float>>.stride,index: 1)
                e.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); e.endEncoding()
            case "matteHistory":
                if historyMode == .reset || historyMode == .blend {
                    guard let historyVideoTexture, let historyMatteTexture,
                          let encoder = command.makeBlitCommandEncoder() else {
                        matteHistoryPolicy.reset(); throw StudioAssetError.invalid("matte history encoder")
                    }
                    encoder.label = "Retain previous video and matte on GPU"
                    encoder.waitForFence(matteFence)
                    encoder.copy(from: videoTexture,to: historyVideoTexture)
                    encoder.copy(from: matteTexture,to: historyMatteTexture)
                    encoder.endEncoding()
                }
            default: break // Normalize is encoded in its isolated timing command buffer.
            }
        }
        let timing = ConversionTiming(conversion)
        command.addCompletedHandler { completed in
            metrics.recordGPUCompletion(start: timing.buffer.gpuStartTime,end: completed.gpuEndTime,budget: settings.profile.gpuBudgetMilliseconds)
        }
        matteHistoryPolicy = nextMattePolicy
        return command
    }

    private func dispatch(_ e: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth, h = max(1,min(8,pipeline.maxTotalThreadsPerThreadgroup/w))
        e.dispatchThreads(MTLSize(width: width,height: height,depth: 1),threadsPerThreadgroup: MTLSize(width: w,height: h,depth: 1))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye-target)
        let up = abs(z.y) > 0.95 ? SIMD3<Float>(0,0,1) : SIMD3<Float>(0,1,0)
        let x = simd_normalize(simd_cross(up,z)), y = simd_cross(z,x)
        return simd_float4x4(columns: (SIMD4(x.x,y.x,z.x,0),SIMD4(x.y,y.y,z.y,0),SIMD4(x.z,y.z,z.z,0),SIMD4(-simd_dot(x,eye),-simd_dot(y,eye),-simd_dot(z,eye),1)))
    }
}
