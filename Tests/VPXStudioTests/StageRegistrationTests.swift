import XCTest
import simd
@testable import VPXStudio

final class StageRegistrationTests: XCTestCase {
    func matrix(_ position: SIMD3<Float>, angle: Float) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(0,1,0)))
        m.columns.3 = SIMD4(position,1)
        return m
    }
    func assertMatrix(_ actual: simd_float4x4, _ expected: simd_float4x4, file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            for row in 0..<4 { XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 0.0001, file: file, line: line) }
        }
    }
    func registration() throws -> StageRegistration {
        try .anchor(nodeID: UUID(), connectionID: UUID(), referenceSpaceRevision: 3,
            stageFromCamera: matrix(SIMD3(2,3,4), angle: 0.8),
            nodeWorldFromCamera: matrix(SIMD3(-1,2,-3), angle: -0.4),
            now: Date(timeIntervalSince1970: 1000))
    }
    func testAnchorMapsBothPositionAndRotationIntoStage() throws {
        let stageCamera = matrix(SIMD3(2,3,4), angle: 0.8)
        let nodeCamera = matrix(SIMD3(-1,2,-3), angle: -0.4)
        let registration = try registration()
        assertMatrix(registration.transform * nodeCamera, stageCamera)
        let cameraLocalMovement = matrix(SIMD3(0,0,-0.5), angle: 0.2)
        assertMatrix(registration.transform * (nodeCamera * cameraLocalMovement), stageCamera * cameraLocalMovement)
    }
    func testConnectionAndWorldRevisionCannotBeReused() throws {
        let r = try registration()
        XCTAssertTrue(r.matches(nodeID: r.nodeID, connectionID: r.connectionID, referenceSpaceRevision: 3))
        XCTAssertFalse(r.matches(nodeID: UUID(), connectionID: r.connectionID, referenceSpaceRevision: 3))
        XCTAssertFalse(r.matches(nodeID: r.nodeID, connectionID: UUID(), referenceSpaceRevision: 3))
        XCTAssertFalse(r.matches(nodeID: r.nodeID, connectionID: r.connectionID, referenceSpaceRevision: 4))
        XCTAssertFalse(r.matches(nodeID: r.nodeID, connectionID: nil, referenceSpaceRevision: nil))
    }
    func testRejectsScaleReflectionNonfiniteAndNonAffineAnchors() throws {
        for value: Float in [0, 2, -1, .nan, .infinity] {
            var bad = matrix_identity_float4x4; bad[0].x = value
            XCTAssertThrowsError(try StageRegistration.anchor(nodeID: UUID(), connectionID: UUID(), referenceSpaceRevision: 1,
                stageFromCamera: bad, nodeWorldFromCamera: matrix_identity_float4x4, now: Date()))
            XCTAssertThrowsError(try StageRegistration.anchor(nodeID: UUID(), connectionID: UUID(), referenceSpaceRevision: 1,
                stageFromCamera: matrix_identity_float4x4, nodeWorldFromCamera: bad, now: Date()))
        }
        var perspective = matrix_identity_float4x4; perspective[0].w = 1
        XCTAssertThrowsError(try StageRegistration.validateRigid(perspective))
        var extreme = matrix_identity_float4x4; extreme[3].x = .greatestFiniteMagnitude
        XCTAssertThrowsError(try StageRegistration.validateRigid(extreme))
        let malformed = StageRegistration(nodeID: UUID(), connectionID: UUID(), referenceSpaceRevision: 1,
            anchoredAt: Date(), stageFromNodeWorld: [1,2,3])
        XCTAssertThrowsError(try malformed.validate())
    }
    func testTimingRequiresAlignedFreshFiniteMeasurements() {
        XCTAssertTrue(StageAnchorTiming.accepts(videoHostSeconds: 1.04, poseHostNanoseconds: 1_060_000_000, now: 1_100_000_000))
        XCTAssertFalse(StageAnchorTiming.accepts(videoHostSeconds: 1, poseHostNanoseconds: 1_100_000_000, now: 1_120_000_000))
        XCTAssertFalse(StageAnchorTiming.accepts(videoHostSeconds: 1, poseHostNanoseconds: 1_000_000_000, now: 1_200_000_000))
        XCTAssertFalse(StageAnchorTiming.accepts(videoHostSeconds: 1.2, poseHostNanoseconds: 1_200_000_000, now: 1_100_000_000))
        XCTAssertFalse(StageAnchorTiming.accepts(videoHostSeconds: nil, poseHostNanoseconds: 1, now: 1))
        XCTAssertFalse(StageAnchorTiming.accepts(videoHostSeconds: .nan, poseHostNanoseconds: .infinity, now: 1))
    }
    func testRegistrationPersistsInsideCalibrationAndRejectsWrongNode() throws {
        var p = CalibrationProfileTests().profile()
        let r = try registration()
        p.cameraID = r.nodeID; p.stageRegistration = r
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try p.save(to: url)
        let loaded = try CalibrationProfile.loadCameraOrProfile(url).1
        XCTAssertEqual(loaded, p)
        p.cameraID = UUID()
        XCTAssertThrowsError(try p.validate())
    }
    func testOldProfileRemainsReadableWithoutRegistration() throws {
        let p = CalibrationProfileTests().profile()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(p)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stageRegistration")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(CalibrationProfile.self, from: JSONSerialization.data(withJSONObject: object)).stageRegistration)
    }
    @MainActor func testAnchorUnavailableWithoutVerifiedInputAndTracking() {
        let model = StudioModel()
        XCTAssertFalse(model.canRegisterStage)
        model.registerStage()
        XCTAssertNil(model.calibrationProfile)
        XCTAssertEqual(model.calibrationIssue, .missing)
    }
}
