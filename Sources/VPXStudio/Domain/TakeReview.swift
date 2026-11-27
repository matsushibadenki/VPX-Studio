import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation

struct TakeReviewSnapshot: Sendable {
    let manifest: TakeManifest
    let results: [TakeManifest.IntegrityResult]
    let inspectedAt: Date
    var allVerified: Bool { !results.isEmpty && results.allSatisfy { $0.status == .verified } }
    var hasFailures: Bool { results.contains { [.missing, .modified, .unreadable].contains($0.status) } }

    struct RecompositionAsset: Identifiable {
        let role: TakeManifest.Asset.Role
        let status: TakeManifest.IntegrityStatus
        var id: TakeManifest.Asset.Role { role }
    }

    var recompositionAssets: [RecompositionAsset] {
        let checks: [(TakeManifest.Asset.Role, String?)] = [
            (.sourceFrames, TakeSourceFrame.path), (.camera, nil), (.scene, "scene.vpx.json"), (.diagnostics, "diagnostics.json"),
            (.calibration, manifest.provenance?.calibration?.relativePath ?? "calibration.json"),
            (.pose, "frames.jsonl"), (.matte, "matte.f16le"), (.depth, "depth.bin"), (.lut, "look.cube")
        ]
        let integrity = Dictionary(results.map { ($0.relativePath, $0.status) }, uniquingKeysWith: { _, latest in latest })
        return checks.map { role, path in
            let candidates = manifest.assets.filter { $0.role == role && (path == nil || $0.relativePath == path) }
            let statuses = candidates.map { integrity[$0.relativePath] ?? .unverified }
            return RecompositionAsset(role: role, status: statuses.contains(.verified) ? .verified : statuses.first ?? .missing)
        }
    }
}

/// File hashing runs on this actor, away from the UI and render threads.
actor TakeReviewService {
    static let audioEditor = TakeReviewService()

    enum PlaybackError: Error { case reviewChanged, calibrationReferenceMismatch }

    func importAudio(from source: URL, directory: URL, snapshot: TakeReviewSnapshot) async throws -> TakeReviewSnapshot {
        let scopedDirectory = directory.startAccessingSecurityScopedResource()
        defer { if scopedDirectory { directory.stopAccessingSecurityScopedResource() } }
        let scopedSource = source.startAccessingSecurityScopedResource()
        defer { if scopedSource { source.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == snapshot.manifest else { throw PlaybackError.reviewChanged }
        guard snapshot.manifest.assets.contains(where: {
            $0.role == .composite && $0.relativePath == "composite.mov" && $0.sha256 != nil
        }) else { throw TakeManifest.PlaybackError.unsupportedRole }
        let suffix = source.pathExtension.lowercased()
        guard !suffix.isEmpty, suffix.count <= 12, suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else {
            throw StudioAssetError.invalid("Audio filename extension")
        }
        let resolved = source.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw StudioAssetError.invalid("Audio file")
        }
        let token = UUID().uuidString
        let staging = directory.appendingPathComponent(".audio-\(token).\(suffix)")
        let path = "audio-\(token).\(suffix)"
        let destination = directory.appendingPathComponent(path)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: resolved, to: staging)

        let media = AVURLAsset(url: staging)
        let tracks = try await media.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first,
              try await media.loadTracks(withMediaType: .video).isEmpty else {
            throw StudioAssetError.invalid("Independent audio tracks")
        }
        let time = try await track.load(.timeRange)
        guard time.start.isNumeric, time.duration.isNumeric, time.duration > .zero else {
            throw StudioAssetError.invalid("Independent audio duration")
        }
        let hash = try TakeManifest.digest(of: .init(role: .audio, relativePath: staging.lastPathComponent), in: directory)
        let name = String(source.lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().prefix(256))
        var manifest = snapshot.manifest
        manifest.assets.append(.init(role: .audio, relativePath: path, sha256: hash, displayName: name.isEmpty ? nil : name))
        try Task.checkCancellation()
        guard try TakeManifest.load(from: directory) == snapshot.manifest else { throw PlaybackError.reviewChanged }
        try FileManager.default.moveItem(at: staging, to: destination)
        do {
            try manifest.save(to: directory)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return .init(manifest: manifest, results: snapshot.results + [.init(relativePath: path, status: .verified)], inspectedAt: Date())
    }

    func saveAudioSync(_ sync: TakeManifest.AudioSync?, directory: URL,
                       snapshot: TakeReviewSnapshot) throws -> TakeReviewSnapshot {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == snapshot.manifest else { throw PlaybackError.reviewChanged }
        var manifest = snapshot.manifest
        manifest.audioSync = sync
        try manifest.validate()
        if let sync {
            _ = try manifest.verifiedPlaybackURL(relativePath: sync.relativePath, in: directory, audioOnly: true)
        }
        try Task.checkCancellation()
        try manifest.save(to: directory)
        return .init(manifest: manifest, results: snapshot.results, inspectedAt: snapshot.inspectedAt)
    }

    func preparePlayback(directory: URL, manifest: TakeManifest, relativePath: String, audioOnly: Bool = false) throws -> URL {
        try Task.checkCancellation()
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        return try manifest.verifiedPlaybackURL(relativePath: relativePath, in: directory, audioOnly: audioOnly)
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

    func restoreCompositeSettings(directory: URL, manifest: TakeManifest) throws -> RenderConfiguration {
        struct Report: Decodable { let renderConfiguration: RenderConfiguration? }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        let bytes = try manifest.verifiedAssetData(relativePath: "diagnostics.json", role: .diagnostics,
                                                   in: directory, maximumSize: 8 * 1024 * 1024)
        guard let settings = try JSONDecoder().decode(Report.self, from: bytes).renderConfiguration,
              settings.canRestoreCompositeSettings else {
            throw StudioAssetError.invalid("Take composite settings")
        }
        try Task.checkCancellation()
        return settings
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

    func previewMatte(directory: URL, manifest: TakeManifest, row: TakeAuxiliaryTracks.Row) throws -> CGImage {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        guard let matte = row.matte, let width = row.matteWidth, let height = row.matteHeight,
              (1...8192).contains(width), (1...8192).contains(height),
              matte.length == width * height * 2 else { throw StudioAssetError.invalid("Take matte dimensions") }
        let end = matte.offset.addingReportingOverflow(UInt64(matte.length))
        guard !end.overflow else { throw StudioAssetError.invalid("Take matte range") }
        let data = try manifest.verifiedAssetData(relativePath: "matte.f16le", role: .matte, in: directory,
            maximumSize: matte.length, byteRange: matte.offset..<end.partialValue)
        // Bound the display allocation even when the recorded matte is 8K.
        let stride = max(1, (max(width, height) + 1023) / 1024)
        let columns = (width + stride - 1) / stride, rows = (height + stride - 1) / stride
        var pixels = [UInt8]()
        pixels.reserveCapacity(columns * rows)
        try data.withUnsafeBytes { bytes in
            for y in Swift.stride(from: 0, to: height, by: stride) {
                try Task.checkCancellation()
                for x in Swift.stride(from: 0, to: width, by: stride) {
                    let index = (y * width + x) * 2
                    let bits = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                    let alpha = Float(Float16(bitPattern: bits))
                    pixels.append(alpha.isFinite ? UInt8((min(1, max(0, alpha)) * 255).rounded()) : 0)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw StudioAssetError.invalid("Take matte preview")
        }
        return image
    }

    struct DepthPreview: Sendable {
        let depth: CGImage
        let confidence: CGImage
    }

    func previewDepth(directory: URL, manifest: TakeManifest, row: TakeAuxiliaryTracks.Row) throws -> DepthPreview {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try TakeManifest.load(from: directory) == manifest else { throw PlaybackError.reviewChanged }
        guard let depth = row.depth, (1...4096).contains(depth.width), (1...4096).contains(depth.height) else {
            throw StudioAssetError.invalid("Take depth dimensions")
        }
        let width = Int(depth.width), height = Int(depth.height), count = width * height
        guard depth.values.length == count * 4, depth.confidence.length == count else {
            throw StudioAssetError.invalid("Take depth sample sizes")
        }
        let valuesEnd = depth.values.offset.addingReportingOverflow(UInt64(depth.values.length))
        let confidenceEnd = depth.confidence.offset.addingReportingOverflow(UInt64(count))
        guard !valuesEnd.overflow, !confidenceEnd.overflow, valuesEnd.partialValue == depth.confidence.offset else {
            throw StudioAssetError.invalid("Take depth ranges")
        }
        let data = try manifest.verifiedAssetData(relativePath: "depth.bin", role: .depth, in: directory,
            maximumSize: count * 5, byteRange: depth.values.offset..<confidenceEnd.partialValue)
        let step = max(1, (max(width, height) + 1023) / 1024)
        let columns = (width + step - 1) / step, rows = (height + step - 1) / step
        var depthPixels: [UInt8] = [], confidencePixels: [UInt8] = []
        depthPixels.reserveCapacity(columns * rows * 4)
        confidencePixels.reserveCapacity(columns * rows * 4)
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for y in stride(from: 0, to: height, by: step) {
                try Task.checkCancellation()
                for x in stride(from: 0, to: width, by: step) {
                    let index = y * width + x
                    let score = bytes[count * 4 + index]
                    switch score {
                    case 2: confidencePixels += [0, 255, 0, 255]
                    case 1: confidencePixels += [255, 166, 0, 255]
                    case 0: confidencePixels += [255, 0, 0, 255]
                    default: confidencePixels += [0, 0, 0, 255]
                    }
                    let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    let meters = Float(bitPattern: UInt32(littleEndian: bits))
                    guard meters.isFinite, meters > 0, score == 1 || score == 2 else {
                        depthPixels += [0, 0, 0, 255]
                        continue
                    }
                    let t = min(1, meters / 10)
                    let intensity: Float = score == 2 ? 255 : 127.5
                    depthPixels += [UInt8(((1-t)*intensity).rounded()),
                        UInt8(((0.25+0.5*(1-abs(2*t-1)))*intensity).rounded()),
                        UInt8((t*intensity).rounded()), 255]
                }
            }
        }
        func image(_ pixels: [UInt8]) throws -> CGImage {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw StudioAssetError.invalid("Take depth preview")
            }
            return image
        }
        return DepthPreview(depth: try image(depthPixels), confidence: try image(confidencePixels))
    }

    func recompositionFrame(directory: URL, manifest: TakeManifest, frameIndex: Int) throws
        -> (source: TakeSourceFrame, row: TakeAuxiliaryTracks.Row)? {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let rows = try loadFrameIndex(directory: directory, manifest: manifest)
        guard rows.indices.contains(frameIndex), let index = rows[frameIndex].originalVideo else { return nil }
        let layout = try TakeSourceFrame.layout(width: index.width, height: index.height, format: index.format)
        let size = layout.reduce(0) { $0 + $1.rowBytes * $1.rows }
        let end = index.range.offset.addingReportingOverflow(UInt64(size))
        guard index.range.length == size, !end.overflow else { throw StudioAssetError.invalid("Take source range") }
        let data = try manifest.verifiedAssetData(relativePath: TakeSourceFrame.path, role: .sourceFrames, in: directory,
            maximumSize: size, byteRange: index.range.offset..<end.partialValue)
        return (try TakeSourceFrame.decode(index, data: data), rows[frameIndex])
    }

    func loadPlaybackIndex(directory: URL, manifest: TakeManifest) throws
        -> (rows: [TakeAuxiliaryTracks.Row], occlusion: TakeOcclusionSummary?) {
        let rows = try loadFrameIndex(directory: directory, manifest: manifest)
        return (rows, try TakeOcclusionSummary(rows: rows))
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

    func acceptAudioEdit(_ updated: TakeReviewSnapshot, previous: TakeReviewSnapshot, directory: URL) -> Bool {
        guard self.directory == directory, snapshot?.manifest == previous.manifest else { return false }
        snapshot = updated
        return true
    }

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
