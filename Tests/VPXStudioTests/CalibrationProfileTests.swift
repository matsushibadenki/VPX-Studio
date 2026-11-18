import XCTest
import VPXCaptureProtocol
@testable import VPXStudio

final class CalibrationProfileTests: XCTestCase {
    func profile() -> CalibrationProfile {
        var camera = CameraCalibration(name: "Measured", imageWidth: 1920, imageHeight: 1080, fx: 1200, fy: 1200, cx: 960, cy: 540)
        camera.source = .measured
        return CalibrationProfile(id: UUID(), revision: 1, camera: camera, cameraID: UUID(), lensID: "35mm-fixed",
            validatedAt: Date(timeIntervalSince1970: 1000), expiresAt: Date(timeIntervalSince1970: 2000),
            reprojectionRMSEPixels: 0.5, sampleCount: 24)
    }
    func issue(_ p: CalibrationProfile, time: Double = 1500, node: UUID? = nil,
               width: Int = 1920, changed: Bool = false, lens: CaptureLensMetadata? = nil) -> CalibrationProfile.Issue? {
        p.issue(now: Date(timeIntervalSince1970: time), sourceID: node ?? p.cameraID,
                width: width, height: 1080, referenceChanged: changed, capturedLens: lens)
    }
    func testProductionEvidenceAndExpiryBoundaries() throws {
        var p = profile(); try p.validate()
        XCTAssertNil(issue(p)); XCTAssertEqual(issue(p, time: 2000), .expired)
        XCTAssertEqual(issue(p, time: 999), .future)
        XCTAssertEqual(issue(p, node: UUID()), .cameraMismatch)
        XCTAssertEqual(issue(p, width: 1280), .formatMismatch)
        XCTAssertEqual(issue(p, changed: true), .referenceChanged)
        p.camera.source = .estimated; XCTAssertEqual(issue(p), .estimated)
        p.camera.source = .manufacturer; p.reprojectionRMSEPixels = 2.01
        XCTAssertEqual(issue(p), .residual)
    }
    func testRejectsNonRigidTransformsAndMalformedEvidence() {
        var p = profile(); p.camera.worldFromCamera[0] = 2
        XCTAssertThrowsError(try p.validate())
        p = profile(); p.camera.worldFromCamera[0] = -1
        XCTAssertThrowsError(try p.validate())
        p = profile(); p.reprojectionRMSEPixels = .nan
        XCTAssertThrowsError(try p.validate())
        p = profile(); p.schemaVersion = 2
        XCTAssertThrowsError(try p.validate())
        p = profile(); p.expiresAt = p.validatedAt
        XCTAssertThrowsError(try p.validate())
    }
    func testOperatingFocusRangeAndNominalFocalLengthAreGated() {
        var p = profile()
        p.camera.breathing = [.init(focusMeters: 1,focalLengthMillimeters: 35),.init(focusMeters: 3,focalLengthMillimeters: 40)]
        func status(focus: Float, focal: Float = 35) -> CalibrationProfile.Issue? {
            p.issue(now: Date(timeIntervalSince1970: 1500),sourceID: p.cameraID,width: 1920,height: 1080,
                referenceChanged: false,focusDistanceMeters: focus,focalLengthMillimeters: focal)
        }
        XCTAssertNil(status(focus: 1)); XCTAssertNil(status(focus: 3))
        XCTAssertEqual(status(focus: 3.01),.lensConfigurationMismatch)
        XCTAssertEqual(status(focus: .nan),.lensConfigurationMismatch)
        XCTAssertEqual(status(focus: 2,focal: 50),.lensConfigurationMismatch)
    }
    func testCapturedLensChecksCurrentFrameAgainstCalibratedValues() throws {
        var p = profile()
        func lens(_ model: String? = "Wide", focal: Double? = 6.86,
                  aperture: Double? = 1.78, zoom: Double? = 1) -> CaptureLensMetadata {
            .init(model: model, focalLengthMillimeters: focal, fNumber: aperture, digitalZoomRatio: zoom)
        }
        XCTAssertNil(issue(p, lens: lens("Other")))
        p.capturedLens = lens()
        try p.validate()
        p = try JSONDecoder().decode(CalibrationProfile.self, from: JSONEncoder().encode(p))
        XCTAssertNil(issue(p, lens: lens(focal: 6.88, aperture: 1.8, zoom: 1.005)))
        XCTAssertEqual(issue(p, lens: lens("Ultra Wide")), .capturedLensMismatch)
        XCTAssertEqual(issue(p, lens: lens(focal: 9)), .capturedLensMismatch)
        XCTAssertEqual(issue(p, lens: lens(aperture: 2.8)), .capturedLensMismatch)
        XCTAssertEqual(issue(p, lens: lens(zoom: 2)), .capturedLensMismatch)
        XCTAssertEqual(issue(p, lens: lens(zoom: nil)), .lensMetadataUnavailable)
        XCTAssertEqual(issue(p), .lensMetadataUnavailable)
        p.capturedLens = lens(nil, focal: nil, aperture: nil, zoom: nil)
        XCTAssertThrowsError(try p.validate())
    }
    func testMultiviewIntrinsicsCanBeSavedButRequireStageExtrinsics() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var p = profile()
        p.schemaVersion = 2
        p.sampleCount = 6 * 7 * 5
        p.intrinsicsMeasurement = .init(method: "checkerboard-multiview-v1", columns: 7, rows: 5,
            squareSizeMeters: 0.03, viewRMSEPixels: Array(repeating: 0.5, count: 6),
            maximumResidualPixels: 1, reprojectionRMSEPixels: 0.5)
        try p.save(to: url)
        let loaded = try XCTUnwrap(CalibrationProfile.loadCameraOrProfile(url).1)
        XCTAssertEqual(loaded, p)
        XCTAssertEqual(issue(loaded), .extrinsicsMissing)
        p.sampleCount -= 1
        XCTAssertThrowsError(try p.validate())
        p = loaded
        p.schemaVersion = 1
        XCTAssertThrowsError(try p.validate())
    }

    func testPersistenceAndLegacyPreviewMigration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = profile(); try p.save(to: url)
        let (camera, loaded) = try CalibrationProfile.loadCameraOrProfile(url)
        XCTAssertEqual(camera, p.camera); XCTAssertEqual(loaded, p)
        try JSONEncoder().encode(p.camera).write(to: url)
        XCTAssertNil(try CalibrationProfile.loadCameraOrProfile(url).1)
        var invalid = p; invalid.schemaVersion = 99
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(invalid).write(to: url)
        XCTAssertThrowsError(try CalibrationProfile.loadCameraOrProfile(url))
    }
    @MainActor func testUnverifiedCalibrationCannotStartProduction() {
        let model = StudioModel()
        XCTAssertEqual(model.calibrationIssue, .missing)
        model.mode = .live; XCTAssertEqual(model.mode, .build)
        model.mode = .record; XCTAssertEqual(model.mode, .build)
        model.isRecording = true; XCTAssertFalse(model.isRecording)
        model.mode = .rehearse; XCTAssertEqual(model.mode, .rehearse)
    }
}
