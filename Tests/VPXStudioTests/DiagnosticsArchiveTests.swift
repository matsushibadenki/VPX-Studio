import XCTest
@testable import VPXStudio

final class DiagnosticsArchiveTests: XCTestCase {
    func testArchiveRetainsMoreThanMemoryWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("long.jsonl")
        let archive = try DiagnosticsArchive(url: url)
        var history = DiagnosticsEventHistory()
        for index in 1...300 {
            history.observe(stream: .videoInput, state: "s\(index)", hostTime: UInt64(index))
            if index.isMultiple(of: 100) { try await archive.append(history.events) }
        }
        try await archive.close()
        XCTAssertEqual(history.events.count, 256)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 300)
    }
    func testAppendDeduplicationAndRetentionGapSurviveReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let archive = try DiagnosticsArchive(url: url)
        var history = DiagnosticsEventHistory(capacity: 2)
        history.observe(stream: .videoInput, state: "active", hostTime: 1)
        try await archive.append(history.events)
        try await archive.append(history.events)
        for index in 2...5 {
            history.observe(stream: .videoInput, state: "state\(index)", hostTime: UInt64(index))
        }
        try await archive.append(history.events)
        try await archive.close()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try lines.map { try decoder.decode(DiagnosticsArchive.Record.self, from: Data($0.utf8)) }
        XCTAssertEqual(records.map(\.event.sequence), [1, 4, 5])
        XCTAssertEqual(records.map(\.omittedBeforeEvent), [0, 2, 0])
        XCTAssertEqual(Set(records.map(\.sessionID)).count, 1)
    }
}
