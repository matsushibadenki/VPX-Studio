import Foundation

/// Point-in-time measurements; not an end-to-end latency benchmark.
struct DiagnosticsReport: Codable {
    let schemaVersion: Int
    let capturedAt: Date
    let configuration: ProjectConfiguration
    let sourceName: String
    let metrics: RealtimeMetricsSnapshot
    let clockOffsetMilliseconds: Double
    let networkRoundTripMilliseconds: Double
    let networkJitterMilliseconds: Double
    let clockDriftPartsPerMillion: Double
    var nodes: [NodeClock] = []

    struct NodeClock: Codable {
        let nodeID: UUID
        let freshness: ClockFreshness
        let sampleAgeMilliseconds: Double?
        let offsetMilliseconds: Double?
        let roundTripMilliseconds: Double?
        let jitterMilliseconds: Double?
        let driftPartsPerMillion: Double?
        var poseQuality: StreamQuality? = nil
        var poseAgeMilliseconds: Double? = nil
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
