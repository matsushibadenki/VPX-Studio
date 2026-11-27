import Foundation
import CryptoKit

/// Portable description of a take. Paths are relative to the take directory.
struct TakeManifest: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var schemaVersion = currentVersion
    var id: UUID
    var name: String
    var createdAt: Date
    var configuration: ProjectConfiguration
    var assets: [Asset]
    var provenance: TakeProvenance?
    var audioSync: AudioSync?

    struct AudioSync: Codable, Equatable, Sendable {
        let relativePath: String
        let offsetMilliseconds: Int
    }

    struct Asset: Codable, Equatable, Sendable {
        enum Role: String, Codable, Sendable {
            case camera, composite, audio, matte, depth, pose, calibration, scene, color, diagnostics, lut, sourceFrames
        }
        var role: Role
        var relativePath: String
        var sha256: String? = nil
        var displayName: String?
    }

    enum ValidationError: Error, Equatable {
        case invalidProvenance
        case unsupportedVersion(Int)
        case invalidName
        case unsafePath(String)
        case duplicatePath(String)
        case invalidDigest(String)
        case unsafeAsset(String)
    }

    func validate() throws {
        guard (1...Self.currentVersion).contains(schemaVersion) else {
            throw ValidationError.unsupportedVersion(schemaVersion)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalidName
        }
        var paths = Set<String>()
        for asset in assets {
            if let digest = asset.sha256 {
                guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw ValidationError.invalidDigest(asset.relativePath)
                }
            }
            let path = asset.relativePath
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.contains("\\"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !path.contains(":"), !path.contains("\0") else {
                throw ValidationError.unsafePath(path)
            }
            guard paths.insert(path).inserted else {
                throw ValidationError.duplicatePath(path)
            }
        }
        if let audioSync {
            guard (-10_000...10_000).contains(audioSync.offsetMilliseconds),
                  assets.contains(where: { $0.role == .audio && $0.relativePath == audioSync.relativePath && $0.sha256 != nil }),
                  assets.contains(where: { $0.role == .composite && $0.relativePath == "composite.mov" && $0.sha256 != nil }) else {
                throw ValidationError.invalidProvenance
            }
        }
        let luts = assets.filter { $0.role == .lut }
        if !luts.isEmpty {
            guard luts.count == 1, let lut = luts.first,
                  lut.relativePath == CompositeLUT.takeAssetPath, let hash = lut.sha256,
                  let provenance, provenance.kind == .recording,
                  provenance.recording?.lutUsage?.contains(where: { $0.applied && $0.reference?.sha256 == hash }) == true else {
                throw ValidationError.invalidProvenance
            }
        }
        if let provenance {
            guard schemaVersion >= 2 else { throw ValidationError.invalidProvenance }
            try provenance.validate(assets: assets)
        }
    }

    enum IntegrityStatus: String, Codable, Equatable, Sendable {
        case verified, unverified, missing, modified, unreadable
    }

    struct IntegrityResult: Equatable, Sendable {
        let relativePath: String
        let status: IntegrityStatus
    }

    enum PlaybackError: Error { case unsupportedRole, unverified, modified }

    /// Rehashes the selected sealed asset immediately before handing it to AVKit.
    func verifiedPlaybackURL(relativePath: String, in directory: URL, audioOnly: Bool = false) throws -> URL {
        try validate()
        guard let asset = assets.first(where: { $0.relativePath == relativePath }),
              (audioOnly ? asset.role == .audio : asset.role == .camera || asset.role == .composite) else { throw PlaybackError.unsupportedRole }
        guard let expected = asset.sha256 else { throw PlaybackError.unverified }
        let inspected = try Self.inspectAsset(asset, in: directory)
        guard inspected.digest == expected else { throw PlaybackError.modified }
        return inspected.url
    }

    func verifiedAssetData(relativePath: String, role: Asset.Role, in directory: URL, maximumSize: Int? = nil, byteRange: Range<UInt64>? = nil) throws -> Data {
        try validate()
        guard let asset = assets.first(where: { $0.relativePath == relativePath && $0.role == role }) else { throw PlaybackError.unsupportedRole }
        guard let expected = asset.sha256 else { throw PlaybackError.unverified }
        let url = try Self.resolveAsset(asset, in: directory)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        var hasher = SHA256()
        var offset: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            let end = offset + UInt64(chunk.count)
            let startInChunk = max(offset, byteRange?.lowerBound ?? offset)
            let endInChunk = min(end, byteRange?.upperBound ?? end)
            if startInChunk < endInChunk {
                let slice = Int(startInChunk - offset)..<Int(endInChunk - offset)
                if let maximumSize, slice.count > maximumSize - data.count {
                    throw ValidationError.unsafeAsset(relativePath)
                }
                data.append(contentsOf: chunk[slice])
            }
            offset = end
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw PlaybackError.modified }
        if let byteRange, byteRange.upperBound > offset { throw ValidationError.unsafeAsset(relativePath) }
        return data
    }

    /// Call off the realtime/UI thread after recording has closed its files.
    /// The manifest is updated only if every asset can be hashed successfully.
    mutating func sealAssets(in directory: URL) throws {
        try validate()
        let sealed = try assets.map { asset in
            var result = asset
            result.sha256 = try Self.digest(of: asset, in: directory)
            return result
        }
        assets = sealed
    }

    /// Missing legacy hashes remain explicitly unverified, never verified.
    func verifyAssets(in directory: URL) throws -> [IntegrityResult] {
        try validate()
        return try assets.map { asset in
            try Task.checkCancellation()
            let status: IntegrityStatus
            do {
                let actual = try Self.digest(of: asset, in: directory)
                status = asset.sha256.map { $0 == actual ? .verified : .modified } ?? .unverified
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                status = .missing
            } catch {
                status = .unreadable
            }
            return IntegrityResult(relativePath: asset.relativePath, status: status)
        }
    }

    static func digest(of asset: Asset, in directory: URL) throws -> String {
        try inspectAsset(asset, in: directory).digest
    }

    private static func resolveAsset(_ asset: Asset, in directory: URL) throws -> URL {
        try Task.checkCancellation()
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(asset.relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw ValidationError.unsafeAsset(asset.relativePath)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ValidationError.unsafeAsset(asset.relativePath) }
        return url
    }

    private static func inspectAsset(_ asset: Asset, in directory: URL) throws -> (digest: String, url: URL) {
        let url = try resolveAsset(asset, in: directory)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), url)
    }

    func save(to takeDirectory: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: takeDirectory, withIntermediateDirectories: true)
        try data.write(to: takeDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func load(from takeDirectory: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Self.self, from: Data(contentsOf: takeDirectory.appendingPathComponent("manifest.json")))
        try manifest.validate()
        // v1 has no provenance. Migration never invents historical device or
        // software metadata, and loading does not rewrite the file on disk.
        var migrated = manifest
        migrated.schemaVersion = Self.currentVersion
        return migrated
    }
}
