import AVFoundation
import CoreMedia
import XCTest
import Observation
@testable import VPXStudio

final class TakePlaybackTests: XCTestCase {
    func testIndependentAudioPlacementPreservesVideoTimelineAndClipsOverlap() throws {
        let picture = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 3, timescale: 1))
        let sound = CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 4, timescale: 1))
        let late = try XCTUnwrap(TakeAudioAudition.Placement(video: picture, audio: sound, offsetMilliseconds: 500))
        XCTAssertEqual(late.destination, CMTime(value: 15, timescale: 10))
        XCTAssertEqual(late.source.start, sound.start)
        XCTAssertEqual(late.source.duration, CMTime(value: 25, timescale: 10))
        let early = try XCTUnwrap(TakeAudioAudition.Placement(video: picture, audio: sound, offsetMilliseconds: -500))
        XCTAssertEqual(early.destination, picture.start)
        XCTAssertEqual(early.source.start, CMTime(value: 25, timescale: 10))
        XCTAssertEqual(early.source.duration, picture.duration)
        XCTAssertNil(TakeAudioAudition.Placement(video: picture, audio: sound, offsetMilliseconds: 4_000))
    }

    func testAudioTimingReportsTrackOffsetsAndOverlap() throws {
        let video = CMTimeRange(start: .zero, duration: CMTime(value: 100, timescale: 100))
        let audio = CMTimeRange(start: CMTime(value: 5, timescale: 100), duration: CMTime(value: 85, timescale: 100))
        let timing = try XCTUnwrap(TakeAudioTiming(video: video, audio: audio))
        XCTAssertEqual(timing.startOffsetMilliseconds, 50, accuracy: 0.001)
        XCTAssertEqual(timing.endOffsetMilliseconds, -100, accuracy: 0.001)
        XCTAssertEqual(timing.overlapFraction, 0.85, accuracy: 0.001)
        XCTAssertNil(TakeAudioTiming(video: .invalid, audio: audio))
    }

    func testOcclusionSummaryCountsOverlappingReasonsAndFindsNextSegment() throws {
        let results: [TakeDepthOcclusion?] = [
            nil, .init(state: .disabled), .init(state: .evaluated, applied: true, lowConfidence: true),
            .init(state: .evaluated, applied: true, missingSamples: true),
            .init(state: .missingDepth), .init(state: .mismatchedDepth),
            .init(state: .evaluated, lowConfidence: true), .init(state: .unavailable)
        ]
        let rows = results.enumerated().map { index, result in
            TakeAuxiliaryTracks.Row(frameIndex: index, ptsValue: Int64(index), ptsTimescale: 30,
                sourceID: nil, inputSequence: nil, inputHostSeconds: nil, matte: nil,
                matteWidth: nil, matteHeight: nil, depth: nil, pose: nil, depthOcclusion: result)
        }
        XCTAssertNil(try TakeOcclusionSummary(rows: Array(rows.prefix(2))))
        let summary = try XCTUnwrap(TakeOcclusionSummary(rows: rows))
        XCTAssertEqual(summary.enabledFrameCount, 6)
        XCTAssertEqual(summary.appliedRate, 1.0 / 3.0, accuracy: 0.00001)
        XCTAssertEqual(summary.groups[.applied]?.segments.map(\.frames), [2...3])
        XCTAssertEqual(summary.groups[.missingDepth]?.segments.map(\.frames), [3...4])
        XCTAssertEqual(summary.groups[.mismatch]?.frameCount, 1)
        let confidence = try XCTUnwrap(summary.groups[.lowConfidence])
        XCTAssertEqual(confidence.frameCount, 2)
        XCTAssertEqual(confidence.next(after: CMTime(value: 2, timescale: 30))?.frames, 6...6)
        XCTAssertEqual(confidence.next(after: CMTime(value: 7, timescale: 30))?.start, CMTime(value: 2, timescale: 30))
    }

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

    func testIndependentAudioImportSealsBytesAndPersistsSync() async throws {
        let directory = try fixture(role: .composite)
        let source = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: source)
        }
        var manifest = try TakeManifest.load(from: directory)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("media.mov"),
                                         to: directory.appendingPathComponent("composite.mov"))
        manifest.assets[0].relativePath = "composite.mov"
        try manifest.save(to: directory)
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            samples.frameLength = 480
            samples.floatChannelData?[0].initialize(repeating: 0, count: 480)
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: samples)
        }

        let service = TakeReviewService()
        let initial = try await service.inspect(directory: directory)
        let imported = try await service.importAudio(from: source, directory: directory, snapshot: initial)
        let audio = try XCTUnwrap(imported.manifest.assets.last)
        XCTAssertEqual(audio.role, .audio)
        XCTAssertEqual(audio.displayName, source.lastPathComponent)
        XCTAssertNotNil(audio.sha256)
        let copied = try imported.manifest.verifiedPlaybackURL(relativePath: audio.relativePath, in: directory, audioOnly: true)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
        let sync = TakeManifest.AudioSync(relativePath: audio.relativePath, offsetMilliseconds: -120)
        let updated = try await service.saveAudioSync(sync, directory: directory, snapshot: imported)
        let reloaded = try await service.inspect(directory: directory)
        XCTAssertEqual(reloaded.manifest.audioSync, sync)
        XCTAssertTrue(reloaded.allVerified)
        try Data("modified".utf8).write(to: copied)
        do {
            _ = try await service.saveAudioSync(.init(relativePath: audio.relativePath, offsetMilliseconds: 20),
                                                directory: directory, snapshot: updated)
            XCTFail("Modified audio must not be saved as a sync source")
        } catch TakeManifest.PlaybackError.modified {}
        XCTAssertEqual(try TakeManifest.load(from: directory).audioSync, sync)
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
