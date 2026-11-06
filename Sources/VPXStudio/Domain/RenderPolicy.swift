import Foundation

enum LiveQualityProfile: String, CaseIterable, Codable {
    case liveFast, liveQuality, reviewCinema
    var framesPerSecond: Double { self == .reviewCinema ? 15 : 60 }
    var inputTimeoutSeconds: Double { self == .reviewCinema ? 2 : self == .liveQuality ? 0.25 : 0.5 }
    var poseTimeoutSeconds: Double { self == .reviewCinema ? 2 : self == .liveQuality ? 0.15 : 0.5 }
    var gpuBudgetMilliseconds: Double { 1000/framesPerSecond }
    var textureImportBudgetMilliseconds: Double { 2 }
    var conversionBudgetMilliseconds: Double { self == .reviewCinema ? 16 : 4 }
}

enum SDRInputEncoding: String, CaseIterable, Codable {
    case automatic, sRGB, rec709, linear
    var shaderCode: UInt32 { switch self { case .automatic: 0; case .sRGB: 1; case .rec709: 2; case .linear: 3 } }
    func resolved(for metadata: VideoColorMetadata) -> Self? {
        if self != .automatic { return self }
        guard metadata.colorPrimaries == "ITU_R_709_2" else { return nil }
        switch metadata.transferFunction {
        case "sRGB": return .sRGB
        case "ITU_R_709_2": return .rec709
        case "Linear": return .linear
        default: return nil
        }
    }
}

enum CompositeDebugView: String, CaseIterable, Codable { case composite, scene, video, matte }
enum OutputProtection: String, Codable { case normal, inputLost, trackingLost, gpuOverload, unknownColor, unsupportedFormat }

struct RenderConfiguration: Codable {
    let sceneName: String
    let sceneID: UUID
    let calibration: CameraCalibration?
    let qualityProfile: LiveQualityProfile
    let inputEncoding: SDRInputEncoding
    let debugView: CompositeDebugView
    let focalLengthMillimeters: Float
    let radialDistortionK1: Float
    let cameraWorldFromCamera: [Float]
    let focusDistanceMeters: Float
    let chromaEnabled: Bool
    let greenThreshold: Float
    let greenSoftness: Float
}

extension OutputProtection {
    var localizationKey: LocalizationKey {
        switch self {
        case .normal: .stateCurrent
        case .inputLost: .videoInputStale
        case .trackingLost: .trackingProtection
        case .gpuOverload: .gpuProtection
        case .unknownColor: .unknownInputColor
        case .unsupportedFormat: .unsupportedInputFormat
        }
    }
}

struct GPUDeadlineMonitor {
    private(set) var isProtected = false
    private var late = 0
    private var healthy = 0
    mutating func record(milliseconds: Double, budget: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        if milliseconds > budget {
            late += 1; healthy = 0
            if late >= 3 { isProtected = true }
        } else {
            late = 0; healthy += 1
            if healthy >= 10 { isProtected = false }
        }
    }
}

struct TrackingReferenceState {
    private(set) var revision: UInt64?
    private(set) var requiresReset = false
    mutating func observe(_ next: UInt64) {
        if let revision, revision != next { requiresReset = true }
        revision = next
    }
    mutating func reset() { requiresReset = false }
}
