import XCTest
@testable import VPXStudio

final class TakeReviewTests: XCTestCase {
    private func fixture() throws -> (URL, TakeManifest) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("camera content".utf8).write(to: directory.appendingPathComponent("camera.mov"))
        try Data("pose content".utf8).write(to: directory.appendingPathComponent("pose.json"))
        let manifest = TakeManifest(id: UUID(), name: "Review fixture", createdAt: Date(), configuration: .standard,
            assets: [.init(role: .camera, relativePath: "camera.mov"), .init(role: .pose, relativePath: "pose.json")])
        return (directory, manifest)
    }

    func testReviewDetectsChangesAndMissingAssetsWithoutWritingManifest() async throws {
        let (directory, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var manifest = original
        try manifest.sealAssets(in: directory)
        try manifest.save(to: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let service = TakeReviewService()
        let first = try await service.inspect(directory: directory)
        XCTAssertTrue(first.allVerified); XCTAssertFalse(first.hasFailures)
        try Data("modified".utf8).write(to: directory.appendingPathComponent("camera.mov"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("pose.json"))
        let second = try await service.inspect(directory: directory)
        XCTAssertEqual(second.results.map(\.status), [.modified, .missing])
        XCTAssertFalse(second.allVerified); XCTAssertTrue(second.hasFailures)
        XCTAssertTrue(first.allVerified) // A review is an immutable point-in-time result.
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), before)
    }

    func testLegacyHashesAndEmptyTakeNeverClaimVerified() async throws {
        let (directory, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manifest.save(to: directory)
        let service = TakeReviewService()
        let legacy = try await service.inspect(directory: directory)
        XCTAssertEqual(legacy.results.map(\.status), [.unverified, .unverified])
        XCTAssertFalse(legacy.allVerified); XCTAssertFalse(legacy.hasFailures)
        var empty = manifest; empty.assets = []
        try empty.save(to: directory)
        let result = try await service.inspect(directory: directory)
        XCTAssertFalse(result.allVerified)
    }

    func testCancellationIsNotConvertedToUnreadable() async throws {
        let (directory, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manifest.save(to: directory)
        let service = TakeReviewService()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.inspect(directory: directory)
        }
        do { _ = try await task.value; XCTFail("Cancelled inspection should throw") }
        catch is CancellationError {} // No successful snapshot with misleading unreadable rows.
    }

    func testUnsupportedManifestFailsBeforeInspection() async throws {
        let (directory, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manifest.save(to: directory)
        let url = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        do { _ = try await TakeReviewService().inspect(directory: directory); XCTFail("Unsupported version") }
        catch let error as TakeManifest.ValidationError { XCTAssertEqual(error, .unsupportedVersion(999)) }
    }
}
