import Foundation

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
    }

    enum ValidationError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidName
        case unsafePath(String)
        case duplicatePath(String)
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
