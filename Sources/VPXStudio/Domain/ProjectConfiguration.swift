import simd

enum LengthUnit: String, Codable {
    case meters
}

/// VPX Stage space is right-handed: +X right, +Y up, and camera-forward -Z.
/// Every device adapter must supply a transform from its native reference
/// space into this coordinate system before publishing a PoseSample.
struct StageCoordinateSystem: Codable, Equatable {
    let unit: LengthUnit
    let isRightHanded: Bool
    let xAxis: String
    let yAxis: String
    let forwardAxis: String
    let originDescription: String

    static let standard = StageCoordinateSystem(
        unit: .meters,
        isRightHanded: true,
        xAxis: "+X right",
        yAxis: "+Y up",
        forwardAxis: "-Z forward",
        originDescription: "Physical stage origin at floor level"
    )

    func stageTransform(
        sourceTransform: simd_float4x4,
        stageFromSource: simd_float4x4
    ) -> simd_float4x4 {
        stageFromSource * sourceTransform
    }
}

struct VideoProfile: Codable, Equatable {
    let name: String
    let width: Int
    let height: Int
    let framesPerSecond: Double
    let bitDepth: Int

    static let uhd4K60TenBit = VideoProfile(
        name: "UHD 4K 60p 10-bit",
        width: 3_840,
        height: 2_160,
        framesPerSecond: 60,
        bitDepth: 10
    )
}

struct ProjectConfiguration: Codable, Equatable {
    let stageCoordinateSystem: StageCoordinateSystem
    let liveVideoProfile: VideoProfile

    static let standard = ProjectConfiguration(
        stageCoordinateSystem: .standard,
        liveVideoProfile: .uhd4K60TenBit
    )
}
