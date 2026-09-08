import MetalKit
import os

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let backgroundPipelineState: MTLRenderPipelineState
    private let geometryPipelineState: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private let noDepthStencilState: MTLDepthStencilState
    private let textureCache: CVMetalTextureCache
    private let fallbackCameraTexture: MTLTexture
    private let latestVideoFrame: LatestVideoFrameStore
    private let metrics: RealtimeMetricsStore
    private let frameGraph: FrameGraph
    private let settingsLock = NSLock()
    private var storedChromaKeySettings = ChromaKeySettings()
    private var focalLengthMillimeters = CameraRig.preview.lens.focalLengthMillimeters
    private var radialDistortionK1 = CameraRig.preview.lens.radialDistortionK1
    private let log = Logger(subsystem: "jp.vpxstudio", category: "renderer")
    private var startTime = CACurrentMediaTime()

    init?(
        pixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        latestVideoFrame: LatestVideoFrameStore,
        metrics: RealtimeMetricsStore
    ) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.latestVideoFrame = latestVideoFrame
        self.metrics = metrics
        let frameGraph = FrameGraph()
        do {
            try frameGraph.register(FramePass(name: "scene", dependsOn: []))
            try frameGraph.register(FramePass(name: "cameraComposite", dependsOn: ["scene"]))
        } catch {
            return nil
        }
        self.frameGraph = frameGraph

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else {
            return nil
        }
        self.textureCache = textureCache

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.storageMode = .shared
        guard let fallbackCameraTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            return nil
        }
        var fallbackPixel: UInt32 = 0xFF0A0502
        fallbackCameraTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &fallbackPixel,
            bytesPerRow: MemoryLayout<UInt32>.size
        )
        self.fallbackCameraTexture = fallbackCameraTexture

        do {
            guard let shaderURL = Bundle.module.url(forResource: "PreviewShaders", withExtension: "metal") else {
                return nil
            }
            let source = try String(contentsOf: shaderURL, encoding: .utf8)
            let library = try device.makeLibrary(source: source, options: nil)
            let backgroundDescriptor = MTLRenderPipelineDescriptor()
            backgroundDescriptor.vertexFunction = library.makeFunction(name: "backgroundVertex")
            backgroundDescriptor.fragmentFunction = library.makeFunction(name: "cameraFragment")
            backgroundDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            backgroundDescriptor.depthAttachmentPixelFormat = depthPixelFormat
            backgroundDescriptor.colorAttachments[0].isBlendingEnabled = true
            backgroundDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            backgroundDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            backgroundDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            backgroundDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.backgroundPipelineState = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)

            let geometryDescriptor = MTLRenderPipelineDescriptor()
            geometryDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            geometryDescriptor.fragmentFunction = library.makeFunction(name: "previewFragment")
            geometryDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            geometryDescriptor.depthAttachmentPixelFormat = depthPixelFormat
            self.geometryPipelineState = try device.makeRenderPipelineState(descriptor: geometryDescriptor)
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            guard let depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
                return nil
            }
            self.depthStencilState = depthStencilState
            let noDepthDescriptor = MTLDepthStencilDescriptor()
            noDepthDescriptor.depthCompareFunction = .always
            noDepthDescriptor.isDepthWriteEnabled = false
            guard let noDepthStencilState = device.makeDepthStencilState(descriptor: noDepthDescriptor) else {
                return nil
            }
            self.noDepthStencilState = noDepthStencilState
        } catch {
            log.error("Unable to create Metal pipeline: \(error.localizedDescription)")
            return nil
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        var uniforms = PreviewUniforms(
            time: Float(CACurrentMediaTime() - startTime),
            aspectRatio: Float(view.drawableSize.width / max(view.drawableSize.height, 1)),
            verticalFieldOfViewRadians: previewCamera.verticalFieldOfViewRadians
        )

        let inputFrame = latestVideoFrame.read()
        let texture = cameraTexture(for: inputFrame)

        do {
            for pass in try frameGraph.orderedPasses() {
                switch pass.name {
                case "scene":
                    encodeScene(
                        commandBuffer: commandBuffer,
                        renderPassDescriptor: renderPassDescriptor,
                        uniforms: &uniforms
                    )
                case "cameraComposite":
                    encodeCameraComposite(
                        commandBuffer: commandBuffer,
                        renderPassDescriptor: renderPassDescriptor,
                        cameraTexture: texture ?? fallbackCameraTexture,
                        hasVideo: texture != nil
                    )
                default:
                    continue
                }
            }
        } catch {
            log.error("Frame graph encoding failed: \(error.localizedDescription)")
            return
        }
        commandBuffer.present(drawable)
        metrics.recordFrameSubmitted(at: frameStart, inputFrame: inputFrame)
        commandBuffer.addCompletedHandler { [metrics] completedBuffer in
            metrics.recordGPUCompletion(
                start: completedBuffer.gpuStartTime,
                end: completedBuffer.gpuEndTime
            )
        }
        commandBuffer.commit()
    }

    private func cameraTexture(for frame: VideoFrame?) -> MTLTexture? {
        guard let frame else { return nil }
        var metalTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            frame.pixelBuffer,
            nil,
            .bgra8Unorm_srgb,
            width,
            height,
            0,
            &metalTexture
        )
        guard result == kCVReturnSuccess, let metalTexture else { return nil }
        return CVMetalTextureGetTexture(metalTexture)
    }

    private func encodeScene(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        uniforms: inout PreviewUniforms
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.setRenderPipelineState(geometryPipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
        encoder.endEncoding()
    }

    private func encodeCameraComposite(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        cameraTexture: MTLTexture,
        hasVideo: Bool
    ) {
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.depthAttachment.loadAction = .load
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        let chromaSettings = chromaKeySettings
        var chromaKeyUniforms = ChromaKeyUniforms(
            isEnabled: chromaSettings.isEnabled ? 1 : 0,
            hasVideo: hasVideo ? 1 : 0,
            greenThreshold: chromaSettings.greenThreshold,
            greenSoftness: chromaSettings.greenSoftness,
            radialDistortionK1: lensDistortionK1,
            principalPointX: 0.5,
            principalPointY: 0.5,
            padding: 0
        )
        encoder.setRenderPipelineState(backgroundPipelineState)
        encoder.setDepthStencilState(noDepthStencilState)
        encoder.setFragmentTexture(cameraTexture, index: 0)
        encoder.setFragmentBytes(
            &chromaKeyUniforms,
            length: MemoryLayout<ChromaKeyUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func setChromaKey(enabled: Bool, greenThreshold: Float, greenSoftness: Float) {
        settingsLock.lock()
        storedChromaKeySettings = ChromaKeySettings(
            isEnabled: enabled,
            greenThreshold: greenThreshold,
            greenSoftness: greenSoftness
        )
        settingsLock.unlock()
    }

    private var chromaKeySettings: ChromaKeySettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return storedChromaKeySettings
    }

    func setFocalLength(_ millimeters: Float) {
        settingsLock.lock()
        focalLengthMillimeters = max(1, millimeters)
        settingsLock.unlock()
    }

    private var previewCamera: CameraRig {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        var camera = CameraRig.preview
        camera.setFocalLength(focalLengthMillimeters)
        return camera
    }

    func setRadialDistortion(_ coefficient: Float) {
        settingsLock.lock()
        radialDistortionK1 = coefficient
        settingsLock.unlock()
    }

    private var lensDistortionK1: Float {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return radialDistortionK1
    }
}

private struct PreviewUniforms {
    var time: Float
    var aspectRatio: Float
    var verticalFieldOfViewRadians: Float
    var padding: Float = 0
}

private struct ChromaKeyUniforms {
    var isEnabled: Float
    var hasVideo: Float
    var greenThreshold: Float
    var greenSoftness: Float
    var radialDistortionK1: Float
    var principalPointX: Float
    var principalPointY: Float
    var padding: Float
}

private struct ChromaKeySettings {
    var isEnabled = false
    var greenThreshold: Float = 0.12
    var greenSoftness: Float = 0.20
}
