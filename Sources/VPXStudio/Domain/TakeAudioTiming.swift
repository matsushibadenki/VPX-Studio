import AVFoundation

/// Container timing on the MOV timeline. This measures track coverage, not acoustic sync.
struct TakeAudioTiming: Sendable {
    let startOffsetMilliseconds: Double
    let endOffsetMilliseconds: Double
    let overlapFraction: Double

    init?(video: CMTimeRange, audio: CMTimeRange) {
        let videoStart = CMTimeGetSeconds(video.start)
        let videoEnd = CMTimeGetSeconds(video.end)
        let audioStart = CMTimeGetSeconds(audio.start)
        let audioEnd = CMTimeGetSeconds(audio.end)
        guard [videoStart, videoEnd, audioStart, audioEnd].allSatisfy(\.isFinite),
              videoEnd > videoStart, audioEnd > audioStart else { return nil }
        startOffsetMilliseconds = (audioStart - videoStart) * 1_000
        endOffsetMilliseconds = (audioEnd - videoEnd) * 1_000
        let overlap = max(0, min(videoEnd, audioEnd) - max(videoStart, audioStart))
        overlapFraction = min(1, overlap / (videoEnd - videoStart))
    }

    @MainActor static func inspect(_ asset: AVAsset) async throws -> Self? {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        // This is the layout produced by the composite recorder.
        guard videoTracks.count == 1, audioTracks.count == 1,
              let video = videoTracks.first, let audio = audioTracks.first else { return nil }
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        return Self(video: videoRange, audio: audioRange)
    }
}
