import Foundation

struct TakeProvenance: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case configurationSnapshot, recording }
    struct Software: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let build: String
        static var current: Self {
            let bundle = Bundle.main
            return Self(name: "VPX Studio",
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local-build")
        }
    }
    struct Device: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
        let capabilities: [String]
        let role: String
        let connection: String
    }
    struct CalibrationReference: Codable, Equatable, Sendable {
        let id: UUID
        let revision: Int
        let cameraID: UUID
        let relativePath: String
    }
    let kind: Kind
    let software: Software
    let devices: [Device]
    let calibration: CalibrationReference?

    func validate(assets: [TakeManifest.Asset]) throws {
        guard !software.name.isEmpty, !software.version.isEmpty, !software.build.isEmpty,
              Set(devices.map(\.id)).count == devices.count,
              devices.allSatisfy({ !$0.name.isEmpty && !$0.role.isEmpty && !$0.connection.isEmpty &&
                  Set($0.capabilities).count == $0.capabilities.count && $0.capabilities.allSatisfy { !$0.isEmpty } }) else {
            throw TakeManifest.ValidationError.invalidProvenance
        }
        if let calibration {
            guard calibration.revision > 0,
                  assets.contains(where: { $0.role == .calibration && $0.relativePath == calibration.relativePath }) else {
                throw TakeManifest.ValidationError.invalidProvenance
            }
        }
    }
}
