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
    enum PlaybackError: Error { case reviewChanged }

    func preparePlayback(directory: URL, manifest: TakeManifest, relativePath: String) throws -> URL {
        try Task.checkCancellation()
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        return try manifest.verifiedPlaybackURL(relativePath: relativePath, in: directory)
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
