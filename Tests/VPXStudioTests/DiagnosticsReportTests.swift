import XCTest
@testable import VPXStudio

final class DiagnosticsReportTests: XCTestCase {
    func testExportPreservesMeasurementsAndHealth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.json")
        var metrics = RealtimeMetricsSnapshot()
        metrics.inputHealth = .stale
        metrics.inputAgeMilliseconds = 700
        let report = DiagnosticsReport(schemaVersion: 1, capturedAt: Date(), configuration: .standard,
            sourceName: "Camera", metrics: metrics, clockOffsetMilliseconds: -12,
            networkRoundTripMilliseconds: 20, networkJitterMilliseconds: 2, clockDriftPartsPerMillion: 5)
        try report.save(to: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertEqual(restored.metrics.inputHealth, .stale)
        XCTAssertEqual(restored.metrics.inputAgeMilliseconds, 700)
        XCTAssertEqual(restored.clockOffsetMilliseconds, -12)
        XCTAssertEqual(restored.configuration, .standard)
    }
}
