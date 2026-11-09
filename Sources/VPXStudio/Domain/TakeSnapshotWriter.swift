import Foundation

struct TakeSnapshotRequest: Sendable {
    let manifest: TakeManifest
    let diagnostics: Data
    let calibration: Data?
}

/// Publishes a completed directory only after all closed files have hashes.
/// A failed/cancelled export leaves the destination and existing Takes intact.
actor TakeSnapshotWriter {
    enum WriteError: Error { case destinationExists, invalidSnapshot }

    func save(_ request: TakeSnapshotRequest, to destination: URL) throws -> URL {
        try Task.checkCancellation()
        let parent = destination.deletingLastPathComponent()
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw WriteError.destinationExists }
        var expected: [TakeManifest.Asset] = [.init(role: .diagnostics, relativePath: "diagnostics.json")]
        if request.calibration != nil { expected.append(.init(role: .calibration, relativePath: "calibration.json")) }
        guard request.manifest.schemaVersion == TakeManifest.currentVersion,
              request.manifest.provenance?.kind == .configurationSnapshot,
              request.manifest.assets == expected else { throw WriteError.invalidSnapshot }
        try request.manifest.validate()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diagnostics = try decoder.decode(DiagnosticsReport.self, from: request.diagnostics)
        let calibration = try request.calibration.map { try decoder.decode(CalibrationProfile.self, from: $0) }
        try calibration?.validate()
        guard diagnostics.configuration == request.manifest.configuration,
              diagnostics.calibrationProfile == calibration,
              calibration?.id == request.manifest.provenance?.calibration?.id,
              calibration?.revision == request.manifest.provenance?.calibration?.revision,
              calibration?.cameraID == request.manifest.provenance?.calibration?.cameraID else {
            throw WriteError.invalidSnapshot
        }
        let staging = parent.appendingPathComponent(".vpx-snapshot-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try request.diagnostics.write(to: staging.appendingPathComponent("diagnostics.json"), options: .atomic)
        if let data = request.calibration {
            try data.write(to: staging.appendingPathComponent("calibration.json"), options: .atomic)
        }
        var manifest = request.manifest
        try manifest.sealAssets(in: staging)
        try manifest.save(to: staging)
        try Task.checkCancellation()
        // Same-parent rename: never expose an incomplete package as a Take.
        try manager.moveItem(at: staging, to: destination)
        return destination
    }
}
