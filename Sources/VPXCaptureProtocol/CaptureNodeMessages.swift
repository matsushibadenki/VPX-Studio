import Foundation

/// Wire-level capabilities. This target has no AVFoundation or ARKit dependency,
/// allowing the same protocol to be used by the iPhone Capture Node and the Mac Host.
public enum CaptureNodeCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case video
    case pose
    case imu
    case depth
    case lensMetadata
    case timeSync
}

public enum CaptureTrackingQuality: String, Codable, Sendable {
    case nominal
    case degraded
    case limited
    case lost
}

public struct CaptureNodeHello: Codable, Sendable, Equatable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let nodeID: UUID
    public let displayName: String
    public let capabilities: Set<CaptureNodeCapability>

    public init(
        nodeID: UUID,
        displayName: String,
        capabilities: Set<CaptureNodeCapability>,
        protocolVersion: Int = CaptureNodeHello.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.nodeID = nodeID
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

/// Timestamps are monotonic nanoseconds in the sender's clock domain.
public struct CaptureVideoFrameHeader: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let captureTimeNanoseconds: UInt64
    public let width: UInt32
    public let height: UInt32
    public let codec: String
    public let isKeyFrame: Bool

    public init(
        sequence: UInt64,
        captureTimeNanoseconds: UInt64,
        width: UInt32,
        height: UInt32,
        codec: String,
        isKeyFrame: Bool
    ) {
        self.sequence = sequence
        self.captureTimeNanoseconds = captureTimeNanoseconds
        self.width = width
        self.height = height
        self.codec = codec
        self.isKeyFrame = isKeyFrame
    }
}

public struct CapturePosePacket: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let captureTimeNanoseconds: UInt64
    public let translationMeters: [Float]
    public let rotationQuaternion: [Float]
    public let linearVelocityMetersPerSecond: [Float]
    public let angularVelocityRadiansPerSecond: [Float]
    public let quality: CaptureTrackingQuality
    public let referenceSpaceRevision: UInt64

    public init(
        sequence: UInt64,
        captureTimeNanoseconds: UInt64,
        translationMeters: [Float],
        rotationQuaternion: [Float],
        linearVelocityMetersPerSecond: [Float],
        angularVelocityRadiansPerSecond: [Float],
        quality: CaptureTrackingQuality,
        referenceSpaceRevision: UInt64
    ) {
        precondition(translationMeters.count == 3, "Translation requires three components.")
        precondition(rotationQuaternion.count == 4, "Quaternion requires four components.")
        precondition(linearVelocityMetersPerSecond.count == 3, "Velocity requires three components.")
        precondition(angularVelocityRadiansPerSecond.count == 3, "Angular velocity requires three components.")
        self.sequence = sequence
        self.captureTimeNanoseconds = captureTimeNanoseconds
        self.translationMeters = translationMeters
        self.rotationQuaternion = rotationQuaternion
        self.linearVelocityMetersPerSecond = linearVelocityMetersPerSecond
        self.angularVelocityRadiansPerSecond = angularVelocityRadiansPerSecond
        self.quality = quality
        self.referenceSpaceRevision = referenceSpaceRevision
    }
}

public struct CaptureDepthFrameHeader: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let captureTimeNanoseconds: UInt64
    public let width: UInt32
    public let height: UInt32
    public let depthEncoding: String
    public let confidenceEncoding: String?

    public init(
        sequence: UInt64,
        captureTimeNanoseconds: UInt64,
        width: UInt32,
        height: UInt32,
        depthEncoding: String,
        confidenceEncoding: String?
    ) {
        self.sequence = sequence
        self.captureTimeNanoseconds = captureTimeNanoseconds
        self.width = width
        self.height = height
        self.depthEncoding = depthEncoding
        self.confidenceEncoding = confidenceEncoding
    }
}

public struct CaptureClockSample: Codable, Sendable, Equatable {
    public let senderMonotonicNanoseconds: UInt64
    public let echoedHostMonotonicNanoseconds: UInt64?

    public init(senderMonotonicNanoseconds: UInt64, echoedHostMonotonicNanoseconds: UInt64?) {
        self.senderMonotonicNanoseconds = senderMonotonicNanoseconds
        self.echoedHostMonotonicNanoseconds = echoedHostMonotonicNanoseconds
    }
}

/// A four-timestamp exchange using monotonic nanoseconds. Host timestamps use
/// the Host clock; node timestamps use the Capture Node clock.
public struct CaptureClockExchange: Codable, Sendable, Equatable {
    public let hostSendNanoseconds: UInt64
    public let nodeReceiveNanoseconds: UInt64
    public let nodeSendNanoseconds: UInt64
    public let hostReceiveNanoseconds: UInt64

    public init(
        hostSendNanoseconds: UInt64,
        nodeReceiveNanoseconds: UInt64,
        nodeSendNanoseconds: UInt64,
        hostReceiveNanoseconds: UInt64
    ) {
        self.hostSendNanoseconds = hostSendNanoseconds
        self.nodeReceiveNanoseconds = nodeReceiveNanoseconds
        self.nodeSendNanoseconds = nodeSendNanoseconds
        self.hostReceiveNanoseconds = hostReceiveNanoseconds
    }
}

public struct CaptureClockEstimate: Sendable, Equatable {
    /// Add this value to a Host timestamp to express it in the Node clock domain.
    public let nodeClockOffsetNanoseconds: Double
    public let roundTripNanoseconds: Double

    public init(exchange: CaptureClockExchange) throws {
        guard exchange.nodeSendNanoseconds >= exchange.nodeReceiveNanoseconds,
              exchange.hostReceiveNanoseconds >= exchange.hostSendNanoseconds else {
            throw CaptureClockEstimateError.invalidTimestampOrder
        }

        let hostDuration = Double(exchange.hostReceiveNanoseconds)
            - Double(exchange.hostSendNanoseconds)
        let nodeProcessingDuration = Double(exchange.nodeSendNanoseconds)
            - Double(exchange.nodeReceiveNanoseconds)
        let roundTrip = hostDuration - nodeProcessingDuration
        guard roundTrip >= 0 else {
            throw CaptureClockEstimateError.invalidTimestampOrder
        }

        self.roundTripNanoseconds = roundTrip
        self.nodeClockOffsetNanoseconds = (
            (Double(exchange.nodeReceiveNanoseconds) - Double(exchange.hostSendNanoseconds))
                + (Double(exchange.nodeSendNanoseconds) - Double(exchange.hostReceiveNanoseconds))
        ) / 2
    }
}

public enum CaptureClockEstimateError: LocalizedError, Equatable {
    case invalidTimestampOrder

    public var errorDescription: String? {
        "Capture clock exchange timestamps are inconsistent."
    }
}

public enum CaptureMessageKind: String, Codable, Sendable {
    case hello
    case clockSample
    case control
}

public struct CaptureVideoProfile: Codable, Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let frameRate: UInt32
    public let bitRate: UInt32
    public let codec: String

    public init(width: UInt32, height: UInt32, frameRate: UInt32, bitRate: UInt32, codec: String) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitRate = bitRate
        self.codec = codec
    }

    public static let uhd60HEVC = CaptureVideoProfile(
        width: 3_840,
        height: 2_160,
        frameRate: 60,
        bitRate: 45_000_000,
        codec: "hvc1"
    )
}

public enum CaptureNodeControlAction: String, Codable, Sendable {
    case startVideo
    case stopVideo
    case setVideoProfile
    case requestKeyFrame
    case beginClockSync
}

/// Idempotent, acknowledged control-plane command. Commands are always carried
/// inside a `.control` envelope over the reliable, authenticated stream.
public struct CaptureNodeControlCommand: Codable, Sendable, Equatable {
    public let commandID: UUID
    public let action: CaptureNodeControlAction
    public let videoProfile: CaptureVideoProfile?

    public init(
        commandID: UUID = UUID(),
        action: CaptureNodeControlAction,
        videoProfile: CaptureVideoProfile? = nil
    ) {
        self.commandID = commandID
        self.action = action
        self.videoProfile = videoProfile
    }
}

/// A transport-neutral envelope. Payloads are JSON today; the outer framing
/// remains usable if video moves to a separate HEVC stream or datagram path.
public struct CaptureMessageEnvelope: Codable, Sendable, Equatable {
    public let kind: CaptureMessageKind
    public let payload: Data

    public init<Payload: Encodable>(kind: CaptureMessageKind, payload: Payload) throws {
        self.kind = kind
        self.payload = try JSONEncoder().encode(payload)
    }

    public func decodePayload<Payload: Decodable>(_ type: Payload.Type) throws -> Payload {
        try JSONDecoder().decode(type, from: payload)
    }
}

public enum CaptureMessageCodecError: LocalizedError, Equatable {
    case frameTooLarge
    case malformedFrame

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge: "Capture message exceeds the maximum frame size."
        case .malformedFrame: "Capture message frame is malformed."
        }
    }
}

/// Length-prefixed control messages for a reliable transport (TCP/TLS or QUIC).
/// Video payloads do not use this codec; only their headers and control traffic do.
public enum CaptureMessageCodec {
    public static let headerLength = 4
    public static let maximumPayloadLength = 1_048_576

    public static func encode(_ envelope: CaptureMessageEnvelope) throws -> Data {
        let payload = try JSONEncoder().encode(envelope)
        guard payload.count <= maximumPayloadLength else {
            throw CaptureMessageCodecError.frameTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: headerLength)
        result.append(payload)
        return result
    }

    public static func decodeFrame(_ data: Data) throws -> CaptureMessageEnvelope {
        guard data.count >= headerLength else {
            throw CaptureMessageCodecError.malformedFrame
        }
        let declaredLength = payloadLength(in: data.prefix(headerLength))
        guard declaredLength <= maximumPayloadLength,
              data.count == declaredLength + headerLength else {
            throw CaptureMessageCodecError.malformedFrame
        }
        return try JSONDecoder().decode(
            CaptureMessageEnvelope.self,
            from: data.dropFirst(headerLength)
        )
    }

    static func payloadLength(in header: Data.SubSequence) -> Int {
        header.reduce(0) { partialLength, byte in
            (partialLength << 8) | Int(byte)
        }
    }
}

/// Restores complete control messages from an arbitrarily segmented reliable stream.
/// A network read is not a message boundary, so the Host and Capture Node must use
/// this type before decoding control-plane data received over TCP/TLS or QUIC streams.
public struct CaptureMessageStreamDecoder: Sendable {
    private var bufferedData = Data()

    public init() {}

    public var bufferedByteCount: Int {
        bufferedData.count
    }

    public mutating func append(_ data: Data) throws -> [CaptureMessageEnvelope] {
        bufferedData.append(data)
        var messages: [CaptureMessageEnvelope] = []

        while bufferedData.count >= CaptureMessageCodec.headerLength {
            let payloadLength = CaptureMessageCodec.payloadLength(
                in: bufferedData.prefix(CaptureMessageCodec.headerLength)
            )
            guard payloadLength <= CaptureMessageCodec.maximumPayloadLength else {
                bufferedData.removeAll(keepingCapacity: false)
                throw CaptureMessageCodecError.frameTooLarge
            }

            let frameLength = CaptureMessageCodec.headerLength + payloadLength
            guard bufferedData.count >= frameLength else {
                break
            }

            let frame = Data(bufferedData.prefix(frameLength))
            bufferedData.removeFirst(frameLength)
            messages.append(try CaptureMessageCodec.decodeFrame(frame))
        }

        return messages
    }
}
