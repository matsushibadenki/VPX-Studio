import Foundation
import simd

struct CameraCalibration: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case measured, manufacturer, estimated }
    struct BreathingSample: Codable, Equatable, Sendable {
        var focusMeters: Float
        var focalLengthMillimeters: Float
    }
    var schemaVersion = 1
    var name: String
    var source = Source.estimated
    var imageWidth: Float
    var imageHeight: Float
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var k1: Float = 0
    var k2: Float = 0
    var k3: Float = 0
    var p1: Float = 0
    var p2: Float = 0
    var referenceFocalLengthMillimeters: Float = 35
    /// Column-major camera-to-stage transform, meters, right handed, camera looks -Z.
    var worldFromCamera: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    var breathing: [BreathingSample] = []

    func validate() throws {
        let values = [imageWidth,imageHeight,fx,fy,cx,cy,k1,k2,k3,p1,p2,referenceFocalLengthMillimeters] + worldFromCamera
        guard schemaVersion == 1, values.allSatisfy(\.isFinite), imageWidth > 0, imageHeight > 0,
              imageWidth <= 16384, imageHeight <= 16384, name.count <= 128, !name.isEmpty,
              fx >= imageWidth*0.01, fx <= imageWidth*100, fy >= imageHeight*0.01, fy <= imageHeight*100,
              [k1,k2,k3,p1,p2].allSatisfy({ abs($0) <= 10 }), breathing.count <= 1024,
              fx > 0, fy > 0, referenceFocalLengthMillimeters > 0, cx >= 0, cx <= imageWidth, cy >= 0, cy <= imageHeight,
              worldFromCamera.count == 16 else { throw StudioAssetError.invalid("calibration") }
        let matrix = transform
        guard abs(matrix.columns.0.w) < 0.0001, abs(matrix.columns.1.w) < 0.0001,
              abs(matrix.columns.2.w) < 0.0001, abs(matrix.columns.3.w - 1) < 0.0001,
              simd_determinant(matrix).isFinite, abs(simd_determinant(matrix)) > 0.0001 else { throw StudioAssetError.invalid("extrinsics") }
        for (index, sample) in breathing.enumerated() {
            guard sample.focusMeters.isFinite, sample.focusMeters > 0,
                  sample.focalLengthMillimeters.isFinite, sample.focalLengthMillimeters > 0,
                  index == 0 || breathing[index-1].focusMeters < sample.focusMeters else {
                throw StudioAssetError.invalid("breathing")
            }
        }
    }

    var transform: simd_float4x4 {
        guard worldFromCamera.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (SIMD4(worldFromCamera[0],worldFromCamera[1],worldFromCamera[2],worldFromCamera[3]),
            SIMD4(worldFromCamera[4],worldFromCamera[5],worldFromCamera[6],worldFromCamera[7]),
            SIMD4(worldFromCamera[8],worldFromCamera[9],worldFromCamera[10],worldFromCamera[11]),
            SIMD4(worldFromCamera[12],worldFromCamera[13],worldFromCamera[14],worldFromCamera[15])))
    }

    func focalLength(at focus: Float, fallback: Float) -> Float {
        guard let first = breathing.first, let last = breathing.last else { return fallback }
        if focus <= first.focusMeters { return first.focalLengthMillimeters }
        if focus >= last.focusMeters { return last.focalLengthMillimeters }
        for i in 1..<breathing.count where focus <= breathing[i].focusMeters {
            let a = breathing[i-1], b = breathing[i]
            let t = (focus - a.focusMeters) / (b.focusMeters - a.focusMeters)
            return a.focalLengthMillimeters + t * (b.focalLengthMillimeters - a.focalLengthMillimeters)
        }
        return fallback
    }

    static func load(_ url: URL) throws -> Self {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw StudioAssetError.invalid("calibration size") }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try result.validate()
        return result
    }
}

enum StudioAssetError: LocalizedError {
    case invalid(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): "Invalid asset: \(detail)"
        case .unsupported(let detail): "Unsupported asset feature: \(detail)"
        }
    }
}

enum CameraProjection {
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye-target)
        let up = abs(z.y) > 0.95 ? SIMD3<Float>(0,0,1) : SIMD3<Float>(0,1,0)
        let x = simd_normalize(simd_cross(up,z)), y = simd_cross(z,x)
        return simd_float4x4(columns: (SIMD4(x.x,y.x,z.x,0),SIMD4(x.y,y.y,z.y,0),SIMD4(x.z,y.z,z.z,0),SIMD4(-simd_dot(x,eye),-simd_dot(y,eye),-simd_dot(z,eye),1)))
    }
    static func perspective(fx: Float, fy: Float, cx: Float, cy: Float, width: Float, height: Float,
                            near: Float = 0.01, far: Float = 100) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(2*fx/width,0,0,0), SIMD4(0,2*fy/height,0,0),
            SIMD4(1-2*cx/width,2*cy/height-1,far/(near-far),-1),
            SIMD4(0,0,near*far/(near-far),0)))
    }
}
