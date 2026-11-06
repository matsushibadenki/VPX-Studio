import XCTest
@testable import VPXStudio

final class DiagnosticsReportTests: XCTestCase {
    @MainActor
    func testCurrentReportExportsPhaseZeroMeasurementsAndOptionalValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var report = StudioModel().diagnosticsReport()
        XCTAssertEqual(report.schemaVersion, DiagnosticsReport.currentSchemaVersion)
        var sample = RealtimeMetricsSnapshot()
        sample.pipeline.captureToEncodeMilliseconds = 12
        sample.pipeline.transportMilliseconds = 8
        sample.pipeline.residentMemoryBytes = 123_456
        sample.pipeline.knownCPUCopyBytes = 128
        sample.pipeline.ioSurfaceReuseCount = 3
        sample.gpuFrameMilliseconds = 0.5
        report.benchmark = BenchmarkResult(fixture: .standard, startedAt: Date())
        report.benchmark?.measurements = [sample]
        let nodeID = UUID()
        report.nodes = [.init(nodeID: nodeID, freshness: .unmeasured, sampleAgeMilliseconds: nil,
            offsetMilliseconds: nil, roundTripMilliseconds: nil, jitterMilliseconds: nil,
            driftPartsPerMillion: nil, poseCaptureAgeMilliseconds: 45)]
        var history = DiagnosticsEventHistory()
        history.observe(stream: .tracking, nodeID: nodeID, state: "lost", hostTime: 100)
        report.events = history.events
        let url = directory.appendingPathComponent("phase0.json")
        try report.save(to: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: url))
        let pipeline = try XCTUnwrap(restored.benchmark?.measurements.first?.pipeline)
        XCTAssertEqual(pipeline.captureToEncodeMilliseconds, 12)
        XCTAssertEqual(pipeline.transportMilliseconds, 8)
        XCTAssertEqual(pipeline.residentMemoryBytes, 123_456)
        XCTAssertEqual(pipeline.knownCPUCopyBytes, 128)
        XCTAssertEqual(pipeline.ioSurfaceReuseCount, 3)
        XCTAssertNil(pipeline.decodeMilliseconds)
        XCTAssertEqual(restored.benchmark?.fixture.poses.count, 120)
        XCTAssertEqual(restored.nodes.first?.poseCaptureAgeMilliseconds, 45)
        XCTAssertNil(restored.nodes.first?.offsetMilliseconds)
        XCTAssertEqual(restored.events.first?.state, "lost")
        XCTAssertFalse(restored.environment.operatingSystem.isEmpty)
    }

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
