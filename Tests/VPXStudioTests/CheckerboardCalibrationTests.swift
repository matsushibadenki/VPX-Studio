import XCTest
import simd
@testable import VPXStudio

final class CheckerboardCalibrationTests: XCTestCase {
    func camera() -> CameraCalibration {
        var c = CameraCalibration(name: "Known intrinsics",imageWidth: 1920,imageHeight: 1080,fx: 1200,fy: 1100,cx: 960,cy: 540)
        c.source = .manufacturer; c.k1 = -0.08; c.k2 = 0.01; c.p1 = 0.001; c.p2 = -0.002
        return c
    }
    func matrix(position: SIMD3<Double>, y: Double = 0, x: Double = 0) -> simd_double4x4 {
        var result = simd_double4x4(simd_quatd(angle: y,axis: SIMD3(0,1,0))*simd_quatd(angle: x,axis: SIMD3(1,0,0)))
        result.columns.3 = SIMD4(position,1)
        return result
    }
    func observation(camera c: CameraCalibration, source: UUID = UUID(),
                     worldCamera: simd_double4x4? = nil, worldBoard: simd_double4x4 = matrix_identity_double4x4,
                     noise: Double = 0) -> CheckerboardObservation {
        let expected = worldCamera ?? matrix(position: SIMD3(0.2,0.15,3),y: 0.15,x: -0.08)
        var observation = CheckerboardObservation(cameraID: source,lensID: "35mm-fixed",imageWidth: 1920,imageHeight: 1080,
            columns: 6,rows: 5,squareSizeMeters: 0.12,imagePoints: [],
            stageFromBoard: (0..<4).flatMap { [Float(worldBoard[$0].x),Float(worldBoard[$0].y),Float(worldBoard[$0].z),Float(worldBoard[$0].w)] },
            measuredAt: Date(timeIntervalSince1970: 1000),expiresAt: Date(timeIntervalSince1970: 2000))
        // Generate observations from a known VPX camera, independently of the solver.
        observation.imagePoints = observation.objectPoints.enumerated().map { index, point in
            let p = simd_inverse(expected)*worldBoard*SIMD4(point,1)
            let x = p.x/(-p.z), y = -p.y/(-p.z), r2 = x*x+y*y
            let radial = 1+Double(c.k1)*r2+Double(c.k2)*r2*r2+Double(c.k3)*r2*r2*r2
            let u = Double(c.fx)*(x*radial+2*Double(c.p1)*x*y+Double(c.p2)*(r2+2*x*x))+Double(c.cx)
            let v = Double(c.fy)*(y*radial+Double(c.p1)*(r2+2*y*y)+2*Double(c.p2)*x*y)+Double(c.cy)
            return .init(x: u+noise*sin(Double(index)*1.7),y: v+noise*cos(Double(index)*1.3))
        }
        return observation
    }
    func assertPose(_ actual: simd_float4x4, _ expected: simd_double4x4, accuracy: Double,
                    file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 { for row in 0..<4 {
            XCTAssertEqual(Double(actual[column][row]),expected[column][row],accuracy: accuracy,file: file,line: line)
        } }
    }
    func testKnownTiltedPoseWithDistortion() throws {
        let c = camera(), expected = matrix(position: SIMD3(0.2,0.15,3),y: 0.15,x: -0.08)
        let result = try CheckerboardSolver.solve(observation(camera: c,worldCamera: expected),intrinsics: c,now: Date(timeIntervalSince1970: 1500))
        assertPose(result.camera.transform,expected,accuracy: 0.0001)
        XCTAssertLessThan(result.rmsePixels,0.001)
        XCTAssertLessThan(result.measurement.maximumResidualPixels,0.001)
        XCTAssertEqual(result.camera.source,.manufacturer)
    }
    func testNonidentityBoardPoseAndFrontFacingConvention() throws {
        let c = camera()
        let expected = matrix(position: SIMD3(0.1,0.2,3.2),y: 0.1,x: -0.05)
        let board = matrix(position: SIMD3(0.3,-0.2,0.25),y: -0.12,x: 0.1)
        let result = try CheckerboardSolver.solve(observation(camera: c,worldCamera: expected,worldBoard: board),intrinsics: c,now: Date(timeIntervalSince1970: 1500))
        assertPose(result.camera.transform,expected,accuracy: 0.0002)
        let straight = matrix(position: SIMD3(0,0,3))
        let front = try CheckerboardSolver.solve(observation(camera: c,worldCamera: straight),intrinsics: c,now: Date(timeIntervalSince1970: 1500))
        assertPose(front.camera.transform,straight,accuracy: 0.0002)
    }
    func testSubpixelNoiseAndEstimatedIntrinsicsStayEstimated() throws {
        var c = camera(); c.source = .estimated
        let expected = matrix(position: SIMD3(0.2,0.15,3),y: 0.15,x: -0.08)
        let result = try CheckerboardSolver.solve(observation(camera: c,noise: 0.3),intrinsics: c,now: Date(timeIntervalSince1970: 1500))
        XCTAssertLessThan(result.rmsePixels,0.5)
        assertPose(result.camera.transform,expected,accuracy: 0.02)
        XCTAssertEqual(result.camera.source,.estimated)
    }
    func testOutlierAndIncorrectPointOrderAreRejected() {
        let c = camera(); var points = observation(camera: c)
        points.imagePoints[4].x += 80
        XCTAssertThrowsError(try CheckerboardSolver.solve(points,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
        points = observation(camera: c); points.imagePoints.swapAt(3,15)
        XCTAssertThrowsError(try CheckerboardSolver.solve(points,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
    }
    func testDegenerateAndMalformedObservationsAreRejected() {
        let c = camera(); var observation = observation(camera: c)
        observation.imagePoints = observation.imagePoints.indices.map { .init(x: 500+Double($0),y: 500+Double($0)) }
        XCTAssertThrowsError(try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
        observation.columns = 0
        XCTAssertThrowsError(try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
        observation.columns = 6; observation.imagePoints[0].x = .nan
        XCTAssertThrowsError(try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
    }
    func testDimensionsDatesAndNonrigidBoardAreRejected() {
        let c = camera(); var observation = observation(camera: c)
        observation.imageWidth = 1280
        XCTAssertThrowsError(try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
        observation.imageWidth = 1920; observation.measuredAt = Date(timeIntervalSince1970: 1600)
        XCTAssertThrowsError(try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
        observation.measuredAt = Date(timeIntervalSince1970: 1000); observation.stageFromBoard[0] = 2
        XCTAssertThrowsError(try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500)))
    }
    func testBreathingUsesDeclaredFocusWithoutRewritingIntrinsicReference() throws {
        var baseline = camera()
        baseline.breathing = [.init(focusMeters: 1,focalLengthMillimeters: 35),.init(focusMeters: 3,focalLengthMillimeters: 40)]
        var effective = baseline; effective.fx *= 40/35; effective.fy *= 40/35
        let expected = matrix(position: SIMD3(0.2,0.15,3),y: 0.15,x: -0.08)
        var points = observation(camera: effective,worldCamera: expected)
        XCTAssertThrowsError(try CheckerboardSolver.solve(points,intrinsics: baseline,now: Date(timeIntervalSince1970: 1500)))
        points.focusDistanceMeters = 3
        let result = try CheckerboardSolver.solve(points,intrinsics: baseline,now: Date(timeIntervalSince1970: 1500))
        assertPose(result.camera.transform,expected,accuracy: 0.0002)
        XCTAssertEqual(result.camera.fx,baseline.fx)
        XCTAssertEqual(result.camera.breathing,baseline.breathing)
        XCTAssertEqual(result.measurement.focusDistanceMeters,3)
        points.focusDistanceMeters = 4
        XCTAssertThrowsError(try CheckerboardSolver.solve(points,intrinsics: baseline,now: Date(timeIntervalSince1970: 1500)))
    }
    func testMeasurementEvidenceRoundTripsAndFeedsQualityGate() throws {
        let c = camera(), observation = observation(camera: camera())
        let result = try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500))
        var profile = CalibrationProfile(id: UUID(),revision: 1,camera: result.camera,cameraID: observation.cameraID,
            lensID: observation.lensID,validatedAt: observation.measuredAt,expiresAt: observation.expiresAt,
            reprojectionRMSEPixels: result.rmsePixels,sampleCount: observation.imagePoints.count)
        profile.checkerboardMeasurement = result.measurement
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try profile.save(to: url)
        XCTAssertEqual(try CalibrationProfile.loadCameraOrProfile(url).1,profile)
        XCTAssertNil(profile.issue(now: Date(timeIntervalSince1970: 1500),sourceID: observation.cameraID,width: 1920,height: 1080,referenceChanged: false))
        profile.sampleCount -= 1
        XCTAssertThrowsError(try profile.validate())
    }
    @MainActor func testModelPublishesNewRevisionAndPreservesProfileOnBadMeasurement() async throws {
        let model = StudioModel(), source = UUID(), c = camera()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraURL = root.appendingPathComponent("camera.json"), pointsURL = root.appendingPathComponent("points.json")
        try JSONEncoder().encode(c).write(to: cameraURL)
        model.deviceRegistry.register(.init(id: source,displayName: "Synthetic camera",capabilities: [.video]),role: .primaryCamera)
        model.deviceRegistry.updateState(for: source,to: .connected); model.selectSource(source)
        await model.loadCalibration(from: cameraURL)
        var observation = observation(camera: c,source: source)
        observation.measuredAt = Date().addingTimeInterval(-60); observation.expiresAt = Date().addingTimeInterval(3600)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(observation).write(to: pointsURL)
        await model.solveCheckerboard(from: pointsURL)
        XCTAssertNil(model.checkerboardError); XCTAssertFalse(model.isSolvingCheckerboard)
        let profile = try XCTUnwrap(model.calibrationProfile)
        XCTAssertEqual(profile.revision,1); XCTAssertEqual(profile.sampleCount,30)
        XCTAssertNotNil(profile.checkerboardMeasurement); XCTAssertNil(profile.stageRegistration)
        XCTAssertEqual(model.calibrationIssue,.formatMismatch) // No live video supplied.
        observation.expiresAt = Date().addingTimeInterval(86400)
        try encoder.encode(observation).write(to: pointsURL)
        await model.solveCheckerboard(from: pointsURL)
        let revised = try XCTUnwrap(model.calibrationProfile)
        XCTAssertEqual(revised.revision,2); XCTAssertEqual(revised.expiresAt,profile.expiresAt)
        let exported = root.appendingPathComponent("exported.json")
        model.saveCalibration(to: exported)
        XCTAssertEqual(try CalibrationProfile.loadCameraOrProfile(exported).1,revised)
        observation.imagePoints[4].x += 80
        try encoder.encode(observation).write(to: pointsURL)
        await model.solveCheckerboard(from: pointsURL)
        XCTAssertNotNil(model.checkerboardError); XCTAssertEqual(model.calibrationProfile,revised)
        model.mode = .live; XCTAssertEqual(model.mode,.build)
    }
    func testCancelledSolverDoesNotComputeOrPublish() async throws {
        let c = camera(), observation = observation(camera: camera())
        let gate = CheckerboardTestGate()
        let task = Task.detached { await gate.wait(); return try CheckerboardSolver.solve(observation,intrinsics: c,now: Date(timeIntervalSince1970: 1500)) }
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled solve returned a result") }
        catch is CancellationError { }
    }
    func testBundledSyntheticObservationHasDocumentedPose() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent("Examples/Phase3")
        let c = try CameraCalibration.load(base.appendingPathComponent("Intrinsics.json"))
        let points = try CheckerboardObservation.load(base.appendingPathComponent("CheckerboardObservation.json"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z"))
        let result = try CheckerboardSolver.solve(points,intrinsics: c,now: date)
        assertPose(result.camera.transform,matrix(position: SIMD3(0,0,3)),accuracy: 0.0001)
        XCTAssertEqual(result.camera.source,.estimated)
    }
    @MainActor func testForeignCameraAndExpiredIntrinsicsPreserveExistingProfile() async throws {
        let model = StudioModel(), source = UUID(), c = camera()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraURL = root.appendingPathComponent("profile.json"), pointsURL = root.appendingPathComponent("points.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let expired = CalibrationProfile(id: UUID(),revision: 1,camera: c,cameraID: source,lensID: "35mm-fixed",
            validatedAt: Date().addingTimeInterval(-3600),expiresAt: Date().addingTimeInterval(-10),reprojectionRMSEPixels: 0.5,sampleCount: 30)
        try expired.save(to: cameraURL)
        model.deviceRegistry.register(.init(id: source,displayName: "Synthetic",capabilities: [.video]),role: .primaryCamera)
        model.deviceRegistry.updateState(for: source,to: .connected); model.selectSource(source)
        await model.loadCalibration(from: cameraURL)
        let prior = model.calibrationProfile
        var points = observation(camera: c,source: UUID())
        points.measuredAt = Date().addingTimeInterval(-60); points.expiresAt = Date().addingTimeInterval(3600)
        try encoder.encode(points).write(to: pointsURL)
        await model.solveCheckerboard(from: pointsURL)
        XCTAssertEqual(model.checkerboardError,.intrinsicsMismatch); XCTAssertEqual(model.calibrationProfile,prior)
        points.cameraID = source
        try encoder.encode(points).write(to: pointsURL)
        await model.solveCheckerboard(from: pointsURL)
        XCTAssertEqual(model.checkerboardError,.intrinsicsExpired); XCTAssertEqual(model.calibrationProfile,prior)
        XCTAssertFalse(model.isSolvingCheckerboard)
    }
}

private actor CheckerboardTestGate {
    private var open = false
    private var waiting: CheckedContinuation<Void,Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        open = true; waiting?.resume(); waiting = nil
    }
}
