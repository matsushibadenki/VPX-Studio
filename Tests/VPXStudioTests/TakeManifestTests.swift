import XCTest
@testable import VPXStudio

final class TakeManifestTests: XCTestCase {
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
