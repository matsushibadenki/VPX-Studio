import XCTest
@testable import VPXStudio

final class TakeSnapshotTests: XCTestCase {
    @MainActor func testCalibrationSnapshotRetainsReferenceAndRejectsMismatchedRevision() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        var camera = CameraCalibration(name: "Measured", imageWidth: 1920, imageHeight: 1080, fx: 1200, fy: 1200, cx: 960, cy: 540)
        camera.source = .measured
        let profile = CalibrationProfile(id: UUID(), revision: 3, camera: camera, cameraID: UUID(), lensID: "fixed",
            validatedAt: Date(timeIntervalSince1970: 1000), expiresAt: Date(timeIntervalSince1970: 2000),
            reprojectionRMSEPixels: 0.5, sampleCount: 24)
        let input = parent.appendingPathComponent("source-calibration.json")
        try profile.save(to: input)
        let studio = StudioModel()
        await studio.loadCalibration(from: input)
        let request = try studio.takeSnapshotRequest()
        XCTAssertEqual(request.manifest.provenance?.calibration?.id, profile.id)
        XCTAssertEqual(request.manifest.provenance?.calibration?.revision, 3)
        let destination = parent.appendingPathComponent("Take")
        let writer = TakeSnapshotWriter()
        _ = try await writer.save(request, to: destination)
        let review = try await TakeReviewService().inspect(directory: destination)
        XCTAssertTrue(review.allVerified)
        XCTAssertEqual(review.manifest.assets.map(\.role), [.diagnostics, .calibration])
        let service = TakeReviewService()
        let restored = try await service.restoreCalibration(directory: destination,
            manifest: review.manifest, relativePath: "calibration.json")
        XCTAssertEqual(restored, profile)
        XCTAssertThrowsError(try studio.restoreTakeCalibration(restored))
        var invalid = request.manifest
        let provenance = try XCTUnwrap(invalid.provenance)
        invalid.provenance = .init(kind: provenance.kind, software: provenance.software, devices: provenance.devices,
            calibration: .init(id: profile.id, revision: 99, cameraID: profile.cameraID, relativePath: "calibration.json"))
        let rejected = parent.appendingPathComponent("Rejected")
        do {
            _ = try await writer.save(.init(manifest: invalid, diagnostics: request.diagnostics, calibration: request.calibration), to: rejected)
            XCTFail("Mismatched calibration reference")
        } catch TakeSnapshotWriter.WriteError.invalidSnapshot {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        invalid.assets = review.manifest.assets
        try invalid.save(to: destination)
        let mismatched = try TakeManifest.load(from: destination)
        do {
            _ = try await service.restoreCalibration(directory: destination,
                manifest: mismatched, relativePath: "calibration.json")
            XCTFail("A valid hash does not establish the calibration revision")
        } catch TakeReviewService.PlaybackError.calibrationReferenceMismatch {}

    }

    @MainActor func testSnapshotPublishesSealedPackageAndCanBeReviewed() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let studio = StudioModel()
        let deviceID = UUID()
        studio.deviceRegistry.register(.init(id: deviceID, displayName: "Camera A", capabilities: [.video, .pose]), role: .secondaryCamera)
        studio.deviceRegistry.updateState(for: deviceID, to: .connected)
        let request = try studio.takeSnapshotRequest()
        XCTAssertEqual(request.manifest.provenance?.devices.first?.id, deviceID)
        XCTAssertEqual(request.manifest.provenance?.devices.first?.role, "secondaryCamera")
        XCTAssertEqual(request.manifest.provenance?.devices.first?.connection, "connected")
        XCTAssertEqual(request.manifest.provenance?.kind, .configurationSnapshot)
        let destination = parent.appendingPathComponent("Take")
        _ = try await TakeSnapshotWriter().save(request, to: destination)
        let review = try await TakeReviewService().inspect(directory: destination)
        XCTAssertTrue(review.allVerified)
        XCTAssertEqual(review.manifest.schemaVersion, 2)
        XCTAssertEqual(review.manifest.provenance, request.manifest.provenance)
        XCTAssertEqual(review.manifest.assets.map(\.role), [.diagnostics])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("diagnostics.json")), request.diagnostics)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["Take"])
    }

    @MainActor func testDestinationCollisionPreservesExistingFiles() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("existing")
        try Data("keep".utf8).write(to: sentinel)
        let request = try StudioModel().takeSnapshotRequest()
        do { _ = try await TakeSnapshotWriter().save(request, to: sentinel); XCTFail("Must not overwrite") }
        catch TakeSnapshotWriter.WriteError.destinationExists {}
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["existing"])
    }

    @MainActor func testCancellationAndInvalidRequestDoNotPublishTake() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = try StudioModel().takeSnapshotRequest()
        let writer = TakeSnapshotWriter(), destination = parent.appendingPathComponent("Take")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await writer.save(request, to: destination)
        }
        do { _ = try await task.value; XCTFail("Cancelled export") } catch is CancellationError {}
        var invalid = request.manifest
        invalid.assets.append(.init(role: .camera, relativePath: "nonexistent.mov"))
        do {
            _ = try await writer.save(.init(manifest: invalid, diagnostics: request.diagnostics, calibration: nil), to: destination)
            XCTFail("Snapshot must not claim unrecorded video")
        } catch TakeSnapshotWriter.WriteError.invalidSnapshot {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testV1MigrationPreservesHashesAndDoesNotInventProvenanceOrRewriteDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = String(repeating: "a", count: 64)
        let original = TakeManifest(schemaVersion: 1, id: UUID(), name: "Legacy", createdAt: Date(), configuration: .standard,
            assets: [.init(role: .camera, relativePath: "camera.mov", sha256: hash)])
        try original.save(to: directory)
        let url = directory.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: url)
        let migrated = try TakeManifest.load(from: directory)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.assets, original.assets)
        XCTAssertEqual(migrated.id, original.id)
        XCTAssertNil(migrated.provenance)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testInvalidCalibrationReferenceAndDuplicateDeviceAreRejected() throws {
        let device = TakeProvenance.Device(id: UUID(), name: "A", capabilities: ["video"], role: "primaryCamera", connection: "connected")
        var manifest = TakeManifest(id: UUID(), name: "Take", createdAt: Date(), configuration: .standard, assets: [])
        manifest.provenance = .init(kind: .configurationSnapshot, software: .current, devices: [device, device], calibration: nil)
        XCTAssertThrowsError(try manifest.validate())
        manifest.provenance = .init(kind: .configurationSnapshot, software: .current, devices: [device],
            calibration: .init(id: UUID(), revision: 1, cameraID: device.id, relativePath: "calibration.json"))
        XCTAssertThrowsError(try manifest.validate())
        manifest.assets = [.init(role: .calibration, relativePath: "calibration.json")]
        XCTAssertNoThrow(try manifest.validate())
    }
}
