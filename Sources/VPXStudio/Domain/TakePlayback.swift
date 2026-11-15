import AVFoundation
import Observation

private final class TakePlaybackAccess {
    let directory: URL
    private let scoped: Bool
    init(_ directory: URL) {
        self.directory = directory
        scoped = directory.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { directory.stopAccessingSecurityScopedResource() } }
}

@MainActor @Observable
final class TakePlaybackModel {
    private(set) var player: AVPlayer?
    private(set) var isPreparing = false
    private(set) var error: String?
    private var access: TakePlaybackAccess?
    private var task: Task<Void, Never>?
    private(set) var currentAuxiliaryFrame: TakeAuxiliaryTracks.Row?
    private(set) var auxiliaryIndexFailed = false
    private var indexTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var frameIndex: [TakeAuxiliaryTracks.Row] = []
    private var observation: NSKeyValueObservation?
    private var generation = UUID()
    private let service = TakeReviewService()

    func play(directory: URL, snapshot: TakeReviewSnapshot, relativePath: String) {
        stop(); error = nil; isPreparing = true
        access = TakePlaybackAccess(directory)
        let generation = self.generation
        task = Task { [weak self, service] in
            do {
                let url = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest, relativePath: relativePath)
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else { throw PlaybackFailure.unsupportedMedia }
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                let item = AVPlayerItem(asset: asset)
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    let message = item.error?.localizedDescription ?? "Playback failed"
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        stop(); error = message
                    }
                }
                let player = AVPlayer(playerItem: item)
                self.player = player; isPreparing = false; task = nil
                if relativePath == "composite.mov",
                   snapshot.manifest.assets.contains(where: { $0.role == .pose && $0.relativePath == "frames.jsonl" }) {
                    loadFrameIndex(directory: directory, manifest: snapshot.manifest, player: player, generation: generation)
                }
                player.play()
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                stop(); self.error = String(describing: error)
            }
        }
    }

    private func loadFrameIndex(directory: URL, manifest: TakeManifest, player: AVPlayer, generation: UUID) {
        indexTask = Task { [weak self, service] in
            do {
                let rows = try await service.loadFrameIndex(directory: directory, manifest: manifest)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                frameIndex = rows
                updateAuxiliaryFrame(at: player.currentTime())
                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15),
                    queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation, let player = self.player else { return }
                        self.updateAuxiliaryFrame(at: player.currentTime())
                    }
                }
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                auxiliaryIndexFailed = true
            }
        }
    }

    private func updateAuxiliaryFrame(at time: CMTime) {
        guard time.isNumeric else { currentAuxiliaryFrame = nil; return }
        var lower = 0
        var upper = frameIndex.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let row = frameIndex[middle]
            if CMTime(value: row.ptsValue, timescale: row.ptsTimescale) <= time { lower = middle + 1 }
            else { upper = middle }
        }
        currentAuxiliaryFrame = lower > 0 ? frameIndex[lower - 1] : nil
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil; isPreparing = false
        observation?.invalidate(); observation = nil
        indexTask?.cancel()
        indexTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        frameIndex.removeAll()
        currentAuxiliaryFrame = nil
        auxiliaryIndexFailed = false
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        access = nil
    }
    private enum PlaybackFailure: Error { case unsupportedMedia }
}
