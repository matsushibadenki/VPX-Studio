import CoreMedia
import CoreVideo
import Foundation
import simd

enum StreamQuality: String, Codable, CaseIterable {
    case nominal
    case degraded
    case estimated
    case lost
}

enum DeviceCapability: String, Codable, Hashable {
    case video
    case pose
    case lens
    case depth
    case timecode
}

struct DeviceDescriptor: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let capabilities: Set<DeviceCapability>
}

struct ClockSample {
    let sourceTime: CMTime
    let hostTime: CMTime
    let uncertaintyMilliseconds: Double
}

struct VideoColorMetadata: Equatable {
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?

    var summary: String {
        [colorPrimaries, transferFunction, yCbCrMatrix]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static func read(from pixelBuffer: CVPixelBuffer) -> VideoColorMetadata {
        func attachment(_ key: CFString) -> String? {
            CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
        }

        return VideoColorMetadata(
            colorPrimaries: attachment(kCVImageBufferColorPrimariesKey),
            transferFunction: attachment(kCVImageBufferTransferFunctionKey),
            yCbCrMatrix: attachment(kCVImageBufferYCbCrMatrixKey)
        )
    }
}

struct VideoFrame {
    let identifier: UInt64
    let captureTime: CMTime
    /// Host monotonic time at which the adapter received this frame.
    let hostReceiveTime: CMTime
    let colorMetadata: VideoColorMetadata
    let pixelBuffer: CVPixelBuffer
    let quality: StreamQuality
}

struct PoseSample {
    let timestamp: CMTime
    let transform: simd_float4x4
    let linearVelocity: SIMD3<Float>
    let angularVelocity: SIMD3<Float>
    let quality: StreamQuality
}

struct LensSample {
    let timestamp: CMTime
    let focalLengthMillimeters: Float
    let focusDistanceMeters: Float
    let apertureFStop: Float
    let quality: StreamQuality
}

struct DepthFrame {
    let captureTime: CMTime
    let pixelBuffer: CVPixelBuffer
    let quality: StreamQuality
}

protocol VideoSource: AnyObject {
    var descriptor: DeviceDescriptor { get }
    func start() throws
    func stop()
}

protocol PoseSource: AnyObject {
    var descriptor: DeviceDescriptor { get }
    func start() throws
    func stop()
}
