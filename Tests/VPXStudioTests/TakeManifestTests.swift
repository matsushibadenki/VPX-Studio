import XCTest
@testable import VPXStudio

final class TakeManifestTests: XCTestCase {
    func testAssetIntegrityLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("video"), withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("video/camera.mov")
        try Data("abc".utf8).write(to: file)
        var value = manifest()
        XCTAssertEqual(try value.verifyAssets(in: directory).first?.status, .unverified)
        try value.sealAssets(in: directory)
        XCTAssertEqual(value.assets[0].sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try value.save(to: directory)
        let restored = try TakeManifest.load(from: directory)
        XCTAssertEqual(try restored.verifyAssets(in: directory).first?.status, .verified)
        try Data("changed".utf8).write(to: file)
        XCTAssertEqual(try restored.verifyAssets(in: directory).first?.status, .modified)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try restored.verifyAssets(in: directory).first?.status, .missing)
        let before = value
        XCTAssertThrowsError(try value.sealAssets(in: directory))
        XCTAssertEqual(value, before)
    }

    func testRejectsMalformedHash() {
        var value = manifest()
        value.assets[0].sha256 = "not-a-hash"
        XCTAssertThrowsError(try value.validate())
    }

    private func manifest() -> TakeManifest {
        TakeManifest(id: UUID(), name: "Take 1", createdAt: Date(timeIntervalSince1970: 100),
                     configuration: .standard,
                     assets: [.init(role: .camera, relativePath: "video/camera.mov")])
    }

    func testRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = manifest()
        try original.save(to: directory)
        XCTAssertEqual(try TakeManifest.load(from: directory), original)
    }

    func testRejectsUnsupportedVersion() {
        var value = manifest()
        value.schemaVersion = 999
        XCTAssertThrowsError(try value.validate())
    }

    func testRejectsUnsafePaths() {
        for path in ["../outside", "/absolute", "video/../../outside", "video//camera", "video/./camera", "C:\\camera"] {
            var value = manifest()
            value.assets[0].relativePath = path
            XCTAssertThrowsError(try value.validate(), path)
        }
    }

    func testRejectsDuplicateAssets() {
        var value = manifest()
        value.assets.append(value.assets[0])
        XCTAssertThrowsError(try value.validate())
    }
}
