import Foundation
import CryptoKit

/// Portable description of a take. Paths are relative to the take directory.
struct TakeManifest: Codable, Equatable {
    static let currentVersion = 1
    var schemaVersion = currentVersion
    var id: UUID
    var name: String
    var createdAt: Date
    var configuration: ProjectConfiguration
    var assets: [Asset]

    struct Asset: Codable, Equatable {
        enum Role: String, Codable {
            case camera, composite, audio, matte, depth, pose, calibration, scene, color, diagnostics
        }
        var role: Role
        var relativePath: String
        var sha256: String? = nil
    }

    enum ValidationError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidName
        case unsafePath(String)
        case duplicatePath(String)
        case invalidDigest(String)
        case unsafeAsset(String)
    }

    func validate() throws {
        guard schemaVersion == Self.currentVersion else {
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
    }

    enum IntegrityStatus: Equatable {
        case verified, unverified, missing, modified, unreadable
    }

    struct IntegrityResult: Equatable {
        let relativePath: String
        let status: IntegrityStatus
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
        return assets.map { asset in
            let status: IntegrityStatus
            do {
                let actual = try Self.digest(of: asset, in: directory)
                status = asset.sha256.map { $0 == actual ? .verified : .modified } ?? .unverified
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                status = .missing
            } catch {
                status = .unreadable
            }
            return IntegrityResult(relativePath: asset.relativePath, status: status)
        }
    }

    private static func digest(of asset: Asset, in directory: URL) throws -> String {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(asset.relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw ValidationError.unsafeAsset(asset.relativePath)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ValidationError.unsafeAsset(asset.relativePath) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
        return manifest
    }
}
