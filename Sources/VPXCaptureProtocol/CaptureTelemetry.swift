import Foundation

public struct CaptureCameraMetadata: Codable, Sendable, Equatable {
    public let cameraID: String
    public let source: String
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let intrinsics: [Float]?
    public let exposureSeconds: Double?
    public init(cameraID: String, source: String, colorPrimaries: String?, transferFunction: String?, yCbCrMatrix: String?, intrinsics: [Float]? = nil, exposureSeconds: Double? = nil) {
        self.cameraID=cameraID; self.source=source; self.colorPrimaries=colorPrimaries; self.transferFunction=transferFunction
        self.yCbCrMatrix=yCbCrMatrix; self.intrinsics=intrinsics; self.exposureSeconds=exposureSeconds
    }
}

public struct CaptureQualityEvent: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case normal, initializing, excessiveMotion, insufficientFeatures, relocalizing, interrupted, interruptionEnded, failed, disconnected, motionUnavailable
    }
    public let sequence: UInt64
    public let captureTimeNanoseconds: UInt64
    public let quality: CaptureTrackingQuality
    public let reason: Reason
    public let referenceSpaceRevision: UInt64
    public init(sequence: UInt64, captureTimeNanoseconds: UInt64, quality: CaptureTrackingQuality, reason: Reason, referenceSpaceRevision: UInt64) {
        self.sequence=sequence; self.captureTimeNanoseconds=captureTimeNanoseconds; self.quality=quality
        self.reason=reason; self.referenceSpaceRevision=referenceSpaceRevision
    }
}

public struct CaptureDepthPacket: Sendable, Equatable {
    public let header: CaptureDepthFrameHeader
    public let depth: Data
    public let confidence: Data
    public init(header: CaptureDepthFrameHeader, depth: Data, confidence: Data) throws {
        self.header=header; self.depth=depth; self.confidence=confidence
        try validate()
    }
    public func validate() throws {
        guard header.width > 0, header.height > 0, header.width <= 1024, header.height <= 1024,
              header.depthEncoding == "depth-float32-le", header.confidenceEncoding == "confidence-uint8",
              depth.count == Int(header.width)*Int(header.height)*4,
              confidence.count == Int(header.width)*Int(header.height), confidence.allSatisfy({ $0 <= 2 }) else {
            throw CaptureTransportCodecError.malformedPacket
        }
    }
}

public struct CaptureTelemetryOffer: Codable, Sendable {
    public let connectionID: UUID
    public let port: UInt16
    public init(connectionID: UUID, port: UInt16) { self.connectionID=connectionID; self.port=port }
}

public enum CaptureTelemetryPayload: Codable, Sendable, Equatable {
    case pose(CapturePosePacket)
    case diagnostic(CaptureQualityEvent)
}

public struct CaptureDatagramEnvelope: Codable, Sendable, Equatable {
    public let nodeID: UUID
    public let connectionID: UUID
    public let sequence: UInt64
    public let payload: CaptureTelemetryPayload
    public init(nodeID: UUID, connectionID: UUID, sequence: UInt64, payload: CaptureTelemetryPayload) {
        self.nodeID=nodeID; self.connectionID=connectionID; self.sequence=sequence; self.payload=payload
    }
    public static let maximumDatagramBytes = 1200
    public func seal(using protector: CaptureControlMessageProtector) throws -> Data {
        let data = try protector.sealPayload(JSONEncoder().encode(self))
        guard data.count <= Self.maximumDatagramBytes else { throw CaptureTransportCodecError.packetTooLarge }
        return data
    }
    public static func open(_ data: Data, using protector: CaptureControlMessageProtector) throws -> Self {
        guard data.count <= maximumDatagramBytes else { throw CaptureTransportCodecError.packetTooLarge }
        return try JSONDecoder().decode(Self.self, from: protector.openPayload(data))
    }
}

/// Allows bounded reordering, rejects replay, and never grows with session duration.
public struct CaptureReplayWindow: Sendable {
    private var highest: UInt64?
    private var seen = Set<UInt64>()
    public init() {}
    public mutating func accept(_ sequence: UInt64) -> Bool {
        guard !seen.contains(sequence) else { return false }
        if let highest, sequence < highest, highest-sequence >= 128 { return false }
        let top = max(highest ?? sequence,sequence)
        highest=top
        seen=seen.filter { top-$0 < 128 }
        seen.insert(sequence)
        return true
    }
}

public struct CaptureSynchronizationPolicy: Sendable {
    public var maximumUncertaintyNanoseconds: Double = 50_000_000
    public init() {}
    public func accepts(_ stats: CaptureClockStatistics) -> Bool {
        let uncertainty = stats.roundTripNanoseconds/2 + stats.jitterNanoseconds
        return stats.acceptedSampleCount > 0 && stats.roundTripNanoseconds >= 0 && stats.jitterNanoseconds >= 0 &&
            stats.referenceHostNanoseconds.isFinite && stats.referenceHostNanoseconds >= 0 && uncertainty.isFinite && uncertainty >= 0 &&
            uncertainty <= maximumUncertaintyNanoseconds && stats.nodeClockOffsetNanoseconds.isFinite &&
            stats.driftPartsPerMillion.isFinite && abs(stats.driftPartsPerMillion) < 100_000
    }
}
