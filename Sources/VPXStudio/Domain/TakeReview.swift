import CoreMedia
import Foundation
import Observation

struct TakeReviewSnapshot: Sendable {
    let manifest: TakeManifest
    let results: [TakeManifest.IntegrityResult]
    let inspectedAt: Date
    var allVerified: Bool { !results.isEmpty && results.allSatisfy { $0.status == .verified } }
    var hasFailures: Bool { results.contains { [.missing, .modified, .unreadable].contains($0.status) } }
}

/// File hashing runs on this actor, away from the UI and render threads.
actor TakeReviewService {
    enum PlaybackError: Error { case reviewChanged, calibrationReferenceMismatch }

    func preparePlayback(directory: URL, manifest: TakeManifest, relativePath: String) throws -> URL {
        try Task.checkCancellation()
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        return try manifest.verifiedPlaybackURL(relativePath: relativePath, in: directory)
    }
    func restoreScene(directory: URL, manifest: TakeManifest, relativePath: String) throws -> StudioScene {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        guard relativePath == "scene.vpx.json" else { throw TakeManifest.PlaybackError.unsupportedRole }
        let data = try manifest.verifiedAssetData(relativePath: relativePath, role: .scene, in: directory)
        let scene = try JSONDecoder().decode(TakeSceneSnapshot.self, from: data).restore()
        try Task.checkCancellation()
        return scene
    }

    func restoreCalibration(directory: URL, manifest: TakeManifest, relativePath: String) throws -> CalibrationProfile {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        guard let reference = manifest.provenance?.calibration, reference.relativePath == relativePath else {
            throw PlaybackError.calibrationReferenceMismatch
        }
        let data = try manifest.verifiedAssetData(relativePath: relativePath, role: .calibration, in: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(CalibrationProfile.self, from: data)
        try profile.validate()
        guard profile.id == reference.id, profile.revision == reference.revision, profile.cameraID == reference.cameraID else {
            throw PlaybackError.calibrationReferenceMismatch
        }
        try Task.checkCancellation()
        return profile
    }

    func restoreLUT(directory: URL, manifest: TakeManifest, relativePath: String) throws -> CompositeLUT {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        guard let hash = manifest.assets.first(where: { $0.role == .lut && $0.relativePath == relativePath })?.sha256,
              let reference = manifest.provenance?.recording?.lutUsage?
                .compactMap({ $0.applied ? $0.reference : nil }).first(where: { $0.sha256 == hash }) else {
            throw TakeManifest.PlaybackError.unverified
        }
        let bytes = try manifest.verifiedAssetData(relativePath: relativePath, role: .lut, in: directory,
                                                   maximumSize: CompositeLUT.maximumFileSize)
        let lut = try CompositeLUT.parse(bytes, name: reference.name)
        try Task.checkCancellation()
        return lut
    }

    func loadFrameIndex(directory: URL, manifest: TakeManifest) throws -> [TakeAuxiliaryTracks.Row] {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        let data = try manifest.verifiedAssetData(relativePath: "frames.jsonl", role: .pose, in: directory)
        let decoder = JSONDecoder()
        var rows: [TakeAuxiliaryTracks.Row] = []
        var previous = CMTime.invalid
        for line in data.split(separator: 0x0A) {
            try Task.checkCancellation()
            let row = try decoder.decode(TakeAuxiliaryTracks.Row.self, from: Data(line))
            let time = CMTime(value: row.ptsValue, timescale: row.ptsTimescale)
            guard row.frameIndex == rows.count, time.isNumeric, time >= .zero,
                  !previous.isNumeric || time > previous else { throw StudioAssetError.invalid("Take frame index") }
            rows.append(row)
            previous = time
        }
        return rows
    }

    func inspect(directory: URL) throws -> TakeReviewSnapshot {
        try Task.checkCancellation()
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let manifest = try TakeManifest.load(from: directory)
        let results = try manifest.verifyAssets(in: directory)
        try Task.checkCancellation()
        return TakeReviewSnapshot(manifest: manifest, results: results, inspectedAt: Date())
    }
}

@MainActor @Observable
final class TakeReviewModel {
    private(set) var snapshot: TakeReviewSnapshot?
    private(set) var directory: URL?
    private(set) var isLoading = false
    private(set) var error: String?
    private let service = TakeReviewService()
    private let writer = TakeSnapshotWriter()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func open(_ directory: URL) {
        cancel()
        self.directory = directory; snapshot = nil; error = nil; isLoading = true
        let generation = self.generation
        task = Task { [weak self, service] in
            do {
                let snapshot = try await service.inspect(directory: directory)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.snapshot = snapshot; isLoading = false; task = nil
            } catch is CancellationError {
                // Cancellation never becomes an unreadable-asset result.
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.error = String(describing: error); isLoading = false; task = nil
            }
        }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isLoading = false
    }

    func saveSnapshot(_ request: TakeSnapshotRequest, to destination: URL) {
        cancel(); snapshot = nil; error = nil; isLoading = true
        let generation = self.generation
        task = Task { [weak self, writer, service] in
            do {
                let url = try await writer.save(request, to: destination)
                let snapshot = try await service.inspect(directory: url)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                directory = url; self.snapshot = snapshot; isLoading = false; task = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.error = String(describing: error); isLoading = false; task = nil
            }
        }
    }

    func showError(_ error: Error) { cancel(); snapshot = nil; self.error = String(describing: error) }
}
