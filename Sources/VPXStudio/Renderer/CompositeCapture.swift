import Metal
import CoreVideo
import CoreMedia

/// Copies the final drawable before presentation. The writer receives only completed copies.
final class CompositeCapture {
    private let slots = DispatchSemaphore(value: 3)
    private var cache: CVMetalTextureCache?

    private let device: MTLDevice
    private lazy var pack10Bit: MTLComputePipelineState? = {
        guard let url = Bundle.module.url(forResource: "StudioPipeline", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: nil),
              let kernel = library.makeFunction(name: "packCompositeMain10") else { return nil }
        return try? device.makeComputePipelineState(function: kernel)
    }()

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    private struct Copy: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let textures: [CVMetalTexture]
    }

    func encode(_ source: MTLTexture, on command: MTLCommandBuffer, to recorder: CameraTakeRecorder, at time: CMTime,
                auxiliary: TakeAuxiliaryFrame? = nil, matte: MTLTexture? = nil, matteFence: MTLFence? = nil) {
        guard slots.wait(timeout: .now()) == .success else { recorder.dropVideoFrame(); return }
        let width = source.width & ~1
        let height = source.height & ~1
        var buffer: CVPixelBuffer?
        let tenBit = recorder.preserve10Bit
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        var planes: [CVMetalTexture] = []
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard width > 0, height > 0, let cache,
              CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess,
              let buffer else {
            slots.signal()
            recorder.dropVideoFrame()
            return
        }
        func plane(_ format: MTLPixelFormat, width: Int, height: Int, index: Int) -> MTLTexture? {
            var reference: CVMetalTexture?
            let attributes = tenBit ? [kCVMetalTextureUsage: MTLTextureUsage.shaderWrite.rawValue] as CFDictionary : nil
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, attributes, format,
                width, height, index, &reference) == kCVReturnSuccess, let reference else { return nil }
            planes.append(reference)
            return CVMetalTextureGetTexture(reference)
        }
        var destination: MTLTexture?
        if tenBit {
            guard source.pixelFormat == .rgba16Float, let pack10Bit,
                  let luma = plane(.r16Unorm, width: width, height: height, index: 0),
                  let chroma = plane(.rg16Unorm, width: width / 2, height: height / 2, index: 1),
                  let encoder = command.makeComputeCommandEncoder() else {
                slots.signal()
                recorder.dropVideoFrame()
                return
            }
            encoder.setComputePipelineState(pack10Bit)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(luma, index: 1)
            encoder.setTexture(chroma, index: 2)
            encoder.dispatchThreads(MTLSize(width: width / 2, height: height / 2, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        } else {
            destination = plane(.bgra8Unorm, width: width, height: height, index: 0)
            guard destination != nil else {
                slots.signal()
                recorder.dropVideoFrame()
                return
            }
        }
        guard let blit = command.makeBlitCommandEncoder() else {
            command.addCompletedHandler { [slots, copy = Copy(buffer: buffer, textures: planes)] _ in
                withExtendedLifetime(copy) { slots.signal() }
            }
            recorder.dropVideoFrame()
            return
        }
        var matteCopy: TakeMatteCopy?
        if let matte {
            let stride = (width * 2 + 255) & ~255
            guard let storage = source.device.makeBuffer(length: stride * height, options: .storageModeShared) else {
                blit.endEncoding()
                command.addCompletedHandler { [slots, copy = Copy(buffer: buffer, textures: planes)] _ in
                    withExtendedLifetime(copy) { slots.signal() }
                }
                recorder.dropVideoFrame()
                return
            }
            if let matteFence { blit.waitForFence(matteFence) }
            blit.copy(from: matte, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: storage,
                      destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * height)
            matteCopy = TakeMatteCopy(buffer: storage, bytesPerRow: stride, width: width, height: height)
        }
        if let destination {
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        }
        blit.endEncoding()
        let copy = Copy(buffer: buffer, textures: planes)
        command.addCompletedHandler { [slots, copy, matteCopy] completed in
            defer { slots.signal() }
            if completed.status == .completed { recorder.submitVideo(copy.buffer, at: time, auxiliary: auxiliary, matte: matteCopy) }
            else { recorder.dropVideoFrame() }
        }
    }
}
