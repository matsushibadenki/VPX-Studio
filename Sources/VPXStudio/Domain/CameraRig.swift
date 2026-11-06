import simd

/// The render-facing representation of a physical or iPhone camera.
struct CameraRig {
    struct Sensor {
        var widthMillimeters: Float
        var heightMillimeters: Float
        var activeResolution: SIMD2<UInt32>
    }

    struct Lens {
        var focalLengthMillimeters: Float
        var focusDistanceMeters: Float
        var apertureFStop: Float
        /// First-order radial distortion coefficient around the principal point.
        var radialDistortionK1: Float
    }

    var sensor: Sensor
    var lens: Lens
    var worldFromCamera: simd_float4x4
    var calibration: CameraCalibration?

    func projection(aspectRatio: Float) -> simd_float4x4 {
        if let c = calibration {
            let focal = c.focalLength(at: lens.focusDistanceMeters, fallback: lens.focalLengthMillimeters)
            let scale = focal / c.referenceFocalLengthMillimeters
            return CameraProjection.perspective(fx: c.fx*scale, fy: c.fy*scale, cx: c.cx, cy: c.cy,
                                                width: c.imageWidth, height: c.imageHeight)
        }
        let fy = 1 / tan(verticalFieldOfViewRadians/2)
        return CameraProjection.perspective(fx: fy/aspectRatio, fy: fy, cx: 1, cy: 1, width: 2, height: 2)
    }

    var verticalFieldOfViewRadians: Float {
        2 * atan(sensor.heightMillimeters / (2 * lens.focalLengthMillimeters))
    }

    mutating func setFocalLength(_ millimeters: Float) {
        lens.focalLengthMillimeters = max(1, millimeters)
    }

    static let preview = CameraRig(
        sensor: .init(
            widthMillimeters: 36,
            heightMillimeters: 20.25,
            activeResolution: SIMD2(3840, 2160)
        ),
        lens: .init(
            focalLengthMillimeters: 35,
            focusDistanceMeters: 3,
            apertureFStop: 4,
            radialDistortionK1: 0
        ),
        worldFromCamera: matrix_identity_float4x4
    )
}
