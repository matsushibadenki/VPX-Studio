import AVFoundation

enum TakeAudioAudition {
    enum Failure: Error { case unsupportedTracks, invalidTiming, unsupportedExport, invalidDestination }

    struct Placement {
        let source: CMTimeRange
        let destination: CMTime

        init?(video: CMTimeRange, audio: CMTimeRange, offsetMilliseconds: Int) {
            guard video.isValid, audio.isValid, video.start.isNumeric, audio.start.isNumeric,
                  video.end.isNumeric, audio.end.isNumeric, video.start >= .zero,
                  (-10_000...10_000).contains(offsetMilliseconds) else { return nil }
            let shift = CMTime(value: Int64(offsetMilliseconds), timescale: 1_000)
            let desiredStart = video.start + shift
            let start = max(video.start, desiredStart)
            let end = min(video.end, desiredStart + audio.duration)
            guard end > start else { return nil }
            source = CMTimeRange(start: audio.start + (start - desiredStart), duration: end - start)
            destination = start
        }
    }

    @MainActor static func export(composition: AVMutableComposition, to destination: URL) async throws {
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".vpx-audio-export-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard !FileManager.default.fileExists(atPath: destination.path),
              destination.pathExtension.lowercased() == "mov" else { throw Failure.invalidDestination }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mov) else { throw Failure.unsupportedExport }
        try await session.export(to: staging, as: .mov)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    @MainActor static func build(video: AVAsset, audio: AVAsset, offsetMilliseconds: Int) async throws
        -> (composition: AVMutableComposition, timing: TakeAudioTiming) {
        let videos = try await video.loadTracks(withMediaType: .video)
        let audios = try await audio.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count == 1,
              let videoTrack = videos.first, let audioTrack = audios.first else {
            throw Failure.unsupportedTracks
        }
        let videoTime = try await videoTrack.load(.timeRange)
        let audioTime = try await audioTrack.load(.timeRange)
        guard let placement = Placement(video: videoTime, audio: audioTime, offsetMilliseconds: offsetMilliseconds) else {
            throw Failure.invalidTiming
        }
        let transform = try await videoTrack.load(.preferredTransform)
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.unsupportedTracks
        }
        try picture.insertTimeRange(videoTime, of: videoTrack, at: videoTime.start)
        picture.preferredTransform = transform
        try sound.insertTimeRange(placement.source, of: audioTrack, at: placement.destination)
        let placedAudio = CMTimeRange(start: placement.destination, duration: placement.source.duration)
        guard let timing = TakeAudioTiming(video: videoTime, audio: placedAudio) else { throw Failure.invalidTiming }
        return (composition, timing)
    }
}
