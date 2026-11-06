import Metal
import Foundation
import VPXCaptureProtocol

struct DepthPreviewInput: Sendable {
    let sourceID: UUID
    let packet: CaptureDepthPacket
    let capturedHostSeconds: Double

    func isCurrent(sourceID: UUID?, now: Double) -> Bool {
        self.sourceID == sourceID && now.isFinite && now >= 0 && capturedHostSeconds.isFinite && capturedHostSeconds >= 0 &&
            now-capturedHostSeconds >= -0.05 && now-capturedHostSeconds <= 0.5
    }
}

struct DepthPreviewTelemetry: Codable, Sendable {
    let available: Bool
    let width: Int?
    let height: Int?
    let ageMilliseconds: Double?
}

/// Uploads only new depth packets. Each pair is immutable after upload so an
/// in-flight command never observes a CPU overwrite of its textures.
final class DepthPreviewTextureCache {
    struct Textures {
        let depth: MTLTexture
        let confidence: MTLTexture
    }
    private struct Key: Equatable {
        let sourceID: UUID
        let sequence: UInt64
        let captureTime: UInt64
        let width: UInt32
        let height: UInt32
    }
    private let device: MTLDevice
    private var key: Key?
    private var cached: Textures?
    private(set) var uploadCount: UInt64 = 0
    init(device: MTLDevice) { self.device = device }

    func clear() { key = nil; cached = nil }

    func textures(for input: DepthPreviewInput?, sourceID: UUID?, now: Double) throws -> Textures? {
        guard let input, input.isCurrent(sourceID: sourceID,now: now) else { clear(); return nil }
        let packet = input.packet, header = packet.header
        let next = Key(sourceID: input.sourceID,sequence: header.sequence,captureTime: header.captureTimeNanoseconds,
            width: header.width,height: header.height)
        if next == key { return cached }
        try packet.validate()
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: Int(header.width),height: Int(header.height),mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
            guard let result = device.makeTexture(descriptor: descriptor) else { throw StudioAssetError.invalid("depth preview texture") }
            return result
        }
        let depth = try texture(.r32Float), confidence = try texture(.r8Uint)
        let region = MTLRegionMake2D(0,0,Int(header.width),Int(header.height))
        packet.depth.withUnsafeBytes { depth.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: Int(header.width)*4) }
        packet.confidence.withUnsafeBytes { confidence.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: Int(header.width)) }
        let result = Textures(depth: depth,confidence: confidence)
        cached = result; key = next; uploadCount &+= 1
        return result
    }
}
