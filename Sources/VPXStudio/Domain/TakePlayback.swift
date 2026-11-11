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
                player.play()
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                stop(); self.error = String(describing: error)
            }
        }
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil; isPreparing = false
        observation?.invalidate(); observation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        access = nil
    }
    private enum PlaybackFailure: Error { case unsupportedMedia }
}
