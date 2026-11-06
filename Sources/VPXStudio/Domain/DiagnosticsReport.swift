import Foundation
import Metal

/// Point-in-time measurements; not an end-to-end latency benchmark.
struct DiagnosticsReport: Codable {
    static let currentSchemaVersion = 6
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
    var events: [DiagnosticsEventHistory.Event] = []
    var discardedEventCount: UInt64 = 0
    var benchmark: BenchmarkResult? = nil
    var environment = DiagnosticsEnvironment.current
    var renderConfiguration: RenderConfiguration?

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
        var poseCaptureAgeMilliseconds: Double? = nil
        var clockUncertaintyMilliseconds: Double? = nil
        var trackingReason: String? = nil
        var depthHighConfidenceFraction: Double? = nil
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct DiagnosticsEnvironment: Codable {
    let operatingSystem: String
    let architecture: String
    let physicalMemoryBytes: UInt64
    let processorCount: Int
    let metalDevice: String?
    let releaseBaseline: String

    static var current: Self {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return Self(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    architecture: architecture, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    processorCount: ProcessInfo.processInfo.activeProcessorCount,
                    metalDevice: MTLCreateSystemDefaultDevice()?.name,
                    releaseBaseline: "macOS15-iOS18-Xcode27.2-Swift6.4.2")
    }
}
