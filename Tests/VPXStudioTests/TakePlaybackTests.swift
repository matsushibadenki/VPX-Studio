import XCTest
import Observation
@testable import VPXStudio

final class TakePlaybackTests: XCTestCase {
    @MainActor func testValidMovieCreatesPlayerAndStopReleasesItem() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try XCTUnwrap(Bundle.module.url(forResource: "ReviewVideo", withExtension: "mov", subdirectory: "Fixtures"))
        let media = directory.appendingPathComponent("media.mov")
        try Data(contentsOf: video).write(to: media)
        var manifest = try TakeManifest.load(from: directory)
        try manifest.sealAssets(in: directory); try manifest.save(to: directory)
        let snapshot = try await TakeReviewService().inspect(directory: directory)
        let playback = TakePlaybackModel()
        playback.play(directory: directory, snapshot: snapshot, relativePath: "media.mov")
        let finished = expectation(description: "Local movie prepared")
        withObservationTracking { _ = playback.isPreparing } onChange: { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(playback.error)
        let player = try XCTUnwrap(playback.player)
        XCTAssertNotNil(player.currentItem)
        playback.stop()
        XCTAssertNil(playback.player)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playback.isPreparing)
    }

    @MainActor func testStopDuringPreparationCannotInstallLatePlayer() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await TakeReviewService().inspect(directory: directory)
        let playback = TakePlaybackModel()
        playback.play(directory: directory, snapshot: snapshot, relativePath: "media.mov")
        XCTAssertTrue(playback.isPreparing)
        playback.stop()
        await Task.yield()
        XCTAssertFalse(playback.isPreparing)
        XCTAssertNil(playback.player)
        XCTAssertNil(playback.error)
    }

    private func fixture(role: TakeManifest.Asset.Role = .camera, sealed: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("media fixture".utf8).write(to: directory.appendingPathComponent("media.mov"))
        var manifest = TakeManifest(id: UUID(), name: "Playback", createdAt: Date(timeIntervalSince1970: 1000),
            configuration: .standard, assets: [.init(role: role, relativePath: "media.mov")])
        if sealed { try manifest.sealAssets(in: directory) }
        try manifest.save(to: directory)
        return directory
    }

    func testCameraAndCompositeAreRehashedAndChangedMediaIsRejected() async throws {
        for role in [TakeManifest.Asset.Role.camera, .composite] {
            let directory = try fixture(role: role)
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = TakeReviewService()
            let snapshot = try await service.inspect(directory: directory)
            let url = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest, relativePath: "media.mov")
            XCTAssertEqual(url.lastPathComponent, "media.mov")
            try Data("changed after review".utf8).write(to: url)
            do {
                _ = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest, relativePath: "media.mov")
                XCTFail("Must rehash before playback")
            } catch TakeManifest.PlaybackError.modified {}
        }
    }

    func testLegacyUnsealedAndNonVideoAssetsCannotPlay() async throws {
        let service = TakeReviewService()
        for role in [TakeManifest.Asset.Role.camera, .pose, .calibration, .scene, .audio] {
            let directory = try fixture(role: role, sealed: role != .camera)
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshot = try await service.inspect(directory: directory)
            do {
                _ = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest, relativePath: "media.mov")
                XCTFail("Only sealed camera/composite assets can play")
            } catch let error as TakeManifest.PlaybackError {
                switch error {
                case .unverified: XCTAssertEqual(role, .camera)
                case .unsupportedRole: XCTAssertNotEqual(role, .camera)
                default: XCTFail("Unexpected failure")
                }
            }
        }
    }

    func testChangedManifestAndMissingMediaInvalidatePreparation() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TakeReviewService()
        let snapshot = try await service.inspect(directory: directory)
        var changed = snapshot.manifest; changed.name = "New take metadata"
        try changed.save(to: directory)
        do {
            _ = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest, relativePath: "media.mov")
            XCTFail("Manifest changed")
        } catch TakeReviewService.PlaybackError.reviewChanged {}
        try snapshot.manifest.save(to: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("media.mov"))
        do {
            _ = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest, relativePath: "media.mov")
            XCTFail("Missing asset")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadNoSuchFile) }
    }

    func testPlaybackRejectsSymlinkOutsideTakeEvenWhenDigestMatches() async throws {
        let directory = try fixture()
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        let service = TakeReviewService()
        let snapshot = try await service.inspect(directory: directory)
        let media = directory.appendingPathComponent("media.mov")
        try FileManager.default.moveItem(at: media, to: outside)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)
        do {
            _ = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest, relativePath: "media.mov")
            XCTFail("Outside asset")
        } catch TakeManifest.ValidationError.unsafeAsset(let path) { XCTAssertEqual(path, "media.mov") }
    }

    @MainActor func testUnsupportedContainerReportsErrorWithoutCreatingPlayer() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await TakeReviewService().inspect(directory: directory)
        let playback = TakePlaybackModel()
        playback.play(directory: directory, snapshot: snapshot, relativePath: "media.mov")
        let finished = expectation(description: "Invalid container rejected")
        withObservationTracking { _ = playback.isPreparing } onChange: { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(playback.isPreparing)
        XCTAssertNil(playback.player)
        XCTAssertNotNil(playback.error)
        playback.stop()
    }
}
