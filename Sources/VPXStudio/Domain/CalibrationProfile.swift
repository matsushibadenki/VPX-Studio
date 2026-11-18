import Foundation
import simd
import VPXCaptureProtocol

/// Portable, versioned evidence for one camera configuration. Legacy camera
/// JSON remains usable for preview but cannot supply missing validation evidence.
struct CalibrationProfile: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var revision: Int
    var camera: CameraCalibration
    var cameraID: UUID
    var lensID: String
    var validatedAt: Date
    var expiresAt: Date
    var reprojectionRMSEPixels: Double
    var sampleCount: Int
    var stageConvention: String = "RH-m-Yup-minusZ"
    var stageRegistration: StageRegistration?
    var capturedLens: CaptureLensMetadata?
    var intrinsicsMeasurement: CheckerboardIntrinsicsMeasurement?
    var checkerboardMeasurement: CheckerboardMeasurement?

    func validate() throws {
        try camera.validate()
        if let lens = capturedLens {
            let values = [lens.focalLengthMillimeters, lens.fNumber, lens.digitalZoomRatio].compactMap { $0 }
            guard lens.model.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 128 }) ?? true,
                  lens.model != nil || !values.isEmpty,
                  values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw StudioAssetError.invalid("calibration lens reference")
            }
        }
        if let measurement = intrinsicsMeasurement {
            try measurement.validate()
            guard camera.source == .measured,
                  checkerboardMeasurement != nil || (
                    sampleCount == measurement.columns * measurement.rows * measurement.viewRMSEPixels.count
                    && abs(reprojectionRMSEPixels - measurement.reprojectionRMSEPixels) < 1e-6
                    && stageRegistration == nil) else {
                throw StudioAssetError.invalid("checkerboard intrinsics evidence")
            }
        }
        if let measurement = checkerboardMeasurement {
            guard measurement.method == "checkerboard-planar-v1",
                  CheckerboardObservation.validTarget(columns: measurement.columns, rows: measurement.rows,
                                                      tagID: measurement.aprilTag36h11ID),
                  measurement.columns*measurement.rows == sampleCount,
                  measurement.squareSizeMeters.isFinite, (0.001...1).contains(measurement.squareSizeMeters),
                  measurement.maximumResidualPixels.isFinite,
                  measurement.maximumResidualPixels >= 0,
                  measurement.maximumResidualPixels >= reprojectionRMSEPixels-1e-6,
                  measurement.imagePoints.count == sampleCount,
                  measurement.imagePoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                    $0.x < Double(camera.imageWidth) && $0.y < Double(camera.imageHeight) }),
                  measurement.stageFromBoard.count == 16,
                  (0...30).contains(measurement.optimizationIterations) else {
                throw StudioAssetError.invalid("checkerboard measurement")
            }
            let v = measurement.stageFromBoard
            try StageRegistration.validateRigid(simd_float4x4(columns: (SIMD4(v[0],v[1],v[2],v[3]),
                SIMD4(v[4],v[5],v[6],v[7]),SIMD4(v[8],v[9],v[10],v[11]),SIMD4(v[12],v[13],v[14],v[15]))))
            if let focus = measurement.focusDistanceMeters {
                guard focus.isFinite, focus > 0 else { throw StudioAssetError.invalid("measurement focus") }
            }
            if let first = camera.breathing.first, let last = camera.breathing.last {
                guard let focus = measurement.focusDistanceMeters, focus >= first.focusMeters, focus <= last.focusMeters else {
                    throw StudioAssetError.invalid("measurement focus range")
                }
            }
        }
        if let stageRegistration {
            try stageRegistration.validate()
            guard stageRegistration.nodeID == cameraID else { throw StudioAssetError.invalid("registration camera") }
        }
        guard schemaVersion == (intrinsicsMeasurement == nil ? 1 : 2), revision > 0, !lensID.isEmpty, lensID.count <= 256,
              validatedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > validatedAt, reprojectionRMSEPixels.isFinite, reprojectionRMSEPixels >= 0,
              sampleCount >= 4, stageConvention == "RH-m-Yup-minusZ" else {
            throw StudioAssetError.invalid("calibration profile")
        }
        guard camera.imageWidth.rounded() == camera.imageWidth, camera.imageHeight.rounded() == camera.imageHeight else {
            throw StudioAssetError.invalid("fractional calibration dimensions")
        }
        // Extrinsics describe a rigid camera pose, never scale, shear or reflection.
        let m = camera.transform
        let axes = [SIMD3(m[0].x,m[0].y,m[0].z), SIMD3(m[1].x,m[1].y,m[1].z), SIMD3(m[2].x,m[2].y,m[2].z)]
        guard axes.allSatisfy({ abs(simd_length($0)-1) < 0.001 }),
              abs(simd_dot(axes[0],axes[1])) < 0.001, abs(simd_dot(axes[0],axes[2])) < 0.001,
              abs(simd_dot(axes[1],axes[2])) < 0.001, simd_determinant(m) > 0.999 else {
            throw StudioAssetError.invalid("non-rigid calibration extrinsics")
        }
    }

    enum Issue: String, Codable { case missing, estimated, expired, future, residual, cameraMismatch, formatMismatch, referenceChanged, stageRegistrationMissing, extrinsicsMissing, lensConfigurationMismatch, lensMetadataUnavailable, capturedLensMismatch }

    func issue(now: Date, sourceID: UUID?, width: Int?, height: Int?, referenceChanged: Bool,
               focusDistanceMeters: Float? = nil, focalLengthMillimeters: Float? = nil, capturedLens liveLens: CaptureLensMetadata? = nil) -> Issue? {
        if referenceChanged { return .referenceChanged }
        if camera.source == .estimated { return .estimated }
        if now < validatedAt { return .future }
        if now >= expiresAt { return .expired }
        if reprojectionRMSEPixels > 2 { return .residual }
        if let measurement = checkerboardMeasurement, measurement.maximumResidualPixels > 5 { return .residual }
        if sourceID != cameraID { return .cameraMismatch }
        if width != Int(camera.imageWidth) || height != Int(camera.imageHeight) { return .formatMismatch }
        if let focal = focalLengthMillimeters,
           !focal.isFinite || abs(focal-camera.referenceFocalLengthMillimeters) > max(0.01,camera.referenceFocalLengthMillimeters*0.001) {
            return .lensConfigurationMismatch
        }
        if let focus = focusDistanceMeters {
            guard focus.isFinite, focus > 0 else { return .lensConfigurationMismatch }
            if let first = camera.breathing.first, let last = camera.breathing.last,
               focus < first.focusMeters || focus > last.focusMeters { return .lensConfigurationMismatch }
        }
        if let expected = capturedLens {
            if let issue = Self.compareLens(expected: expected, observed: liveLens) { return issue }
        }
        if intrinsicsMeasurement != nil && checkerboardMeasurement == nil { return .extrinsicsMissing }
        return nil
    }

    private static func compareLens(expected: CaptureLensMetadata, observed: CaptureLensMetadata?) -> Issue? {
        var missing = false
        if let model = expected.model {
            if let actual = observed?.model, !actual.isEmpty {
                if model != actual { return .capturedLensMismatch }
            } else {
                missing = true
            }
        }
        let comparisons = [
            (expected.focalLengthMillimeters, observed?.focalLengthMillimeters, 0.05),
            (expected.fNumber, observed?.fNumber, 0.05),
            (expected.digitalZoomRatio, observed?.digitalZoomRatio, 0.01)
        ]
        for (reference, actual, tolerance) in comparisons {
            guard let reference else { continue }
            guard let actual, actual.isFinite, actual > 0 else { missing = true; continue }
            if abs(actual - reference) > tolerance { return .capturedLensMismatch }
        }
        return missing ? .lensMetadataUnavailable : nil
    }

    static func loadCameraOrProfile(_ url: URL) throws -> (CameraCalibration, Self?) {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else {
            throw StudioAssetError.invalid("calibration size")
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A profile-shaped document must never fall back to the legacy parser.
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["camera"] != nil {
            let profile = try decoder.decode(Self.self, from: data)
            try profile.validate()
            return (profile.camera, profile)
        }
        let camera = try decoder.decode(CameraCalibration.self, from: data)
        try camera.validate()
        return (camera, nil)
    }

    func save(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension CalibrationProfile.Issue {
    var localizationKey: LocalizationKey {
        switch self {
        case .missing: .calibrationMissing
        case .estimated: .calibrationEstimated
        case .expired: .calibrationExpired
        case .future: .calibrationFuture
        case .residual: .calibrationResidual
        case .cameraMismatch: .calibrationCameraMismatch
        case .formatMismatch: .calibrationFormatMismatch
        case .referenceChanged: .calibrationReferenceChanged
        case .extrinsicsMissing: .calibrationExtrinsicsMissing
        case .stageRegistrationMissing: .stageRegistrationMissing
        case .lensMetadataUnavailable: .calibrationLensMetadataUnavailable
        case .capturedLensMismatch: .calibrationCapturedLensMismatch
        case .lensConfigurationMismatch: .calibrationLensMismatch
        }
    }
}
