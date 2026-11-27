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
    private(set) var audioTiming: TakeAudioTiming?
    private var audioTimingTask: Task<Void, Never>?
    private(set) var occlusionSummary: TakeOcclusionSummary?
    private(set) var auxiliaryIndexFailed = false
    private var indexTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var frameIndex: [TakeAuxiliaryTracks.Row] = []
    private var observation: NSKeyValueObservation?
    private var generation = UUID()
    private let service = TakeReviewService()

    func play(directory: URL, snapshot: TakeReviewSnapshot, relativePath: String,
              audioPath: String? = nil, audioOffsetMilliseconds: Int = 0) {
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
                let playbackAsset: AVAsset
                if let audioPath {
                    guard relativePath == "composite.mov" else { throw PlaybackFailure.unsupportedMedia }
                    let audioURL = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest,
                                                                     relativePath: audioPath, audioOnly: true)
                    let audition = try await TakeAudioAudition.build(
                        video: asset, audio: AVURLAsset(url: audioURL), offsetMilliseconds: audioOffsetMilliseconds)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    playbackAsset = audition.composition
                    audioTiming = audition.timing
                } else {
                    playbackAsset = asset
                }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let item = AVPlayerItem(asset: playbackAsset)
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
                if relativePath == "composite.mov", audioPath == nil {
                    audioTimingTask = Task { [weak self] in
                        let timing = try? await TakeAudioTiming.inspect(playbackAsset)
                        guard let self, !Task.isCancelled, self.generation == generation else { return }
                        audioTiming = timing
                    }
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
                let index = try await service.loadPlaybackIndex(directory: directory, manifest: manifest)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                frameIndex = index.rows
                occlusionSummary = index.occlusion
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

    func jumpToNextOcclusionSegment(_ category: TakeOcclusionSummary.Category) {
        guard let player, let segment = occlusionSummary?.groups[category]?.next(after: player.currentTime()) else { return }
        player.seek(to: segment.start, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil; isPreparing = false
        observation?.invalidate(); observation = nil
        audioTimingTask?.cancel(); audioTimingTask = nil; audioTiming = nil
        indexTask?.cancel()
        indexTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        frameIndex.removeAll()
        occlusionSummary = nil
        currentAuxiliaryFrame = nil
        auxiliaryIndexFailed = false
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        access = nil
    }
    private enum PlaybackFailure: Error { case unsupportedMedia }
}
