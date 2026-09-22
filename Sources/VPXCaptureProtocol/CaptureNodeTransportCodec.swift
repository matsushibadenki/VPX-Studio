import Foundation

/// Payload carried by the encrypted Capture Node transport. Video stays binary
/// end-to-end; it is never expanded into a JSON/Base64 representation.
public enum CaptureTransportPacket: Sendable, Equatable {
    case control(CaptureMessageEnvelope)
    case video(CaptureEncodedVideoFrame)
    case pose(CapturePosePacket)
    case clockProbe(CaptureClockProbe)
    case clockReply(CaptureClockReply)
}

public enum CaptureTransportCodecError: LocalizedError, Equatable {
    case packetTooLarge
    case malformedPacket

    public var errorDescription: String? {
        switch self {
        case .packetTooLarge: "Capture transport packet exceeds the maximum size."
        case .malformedPacket: "Capture transport packet is malformed."
        }
    }
}

public enum CaptureTransportPacketCodec {
    public static let maximumPacketLength = 67_108_864
    private static let controlMarker: UInt8 = 1
    private static let videoMarker: UInt8 = 2
    private static let poseMarker: UInt8 = 3
    private static let clockProbeMarker: UInt8 = 4
    private static let clockReplyMarker: UInt8 = 5

    public static func encode(_ packet: CaptureTransportPacket) throws -> Data {
        var data = Data()
        switch packet {
        case .control(let envelope):
            let payload = try JSONEncoder().encode(envelope)
            data.append(controlMarker)
            try appendLengthPrefixed(payload, to: &data)
        case .video(let frame):
            let header = try JSONEncoder().encode(frame.header)
            guard frame.parameterSets.count <= Int(UInt8.max) else {
                throw CaptureTransportCodecError.malformedPacket
            }
            data.append(videoMarker)
            try appendLengthPrefixed(header, to: &data)
            data.append(UInt8(frame.parameterSets.count))
            for parameterSet in frame.parameterSets {
                try appendLengthPrefixed(parameterSet, to: &data)
            }
            try appendLengthPrefixed(frame.encodedData, to: &data)
        case .pose(let pose):
            data.append(poseMarker)
            try appendLengthPrefixed(JSONEncoder().encode(pose), to: &data)
        case .clockProbe(let probe):
            data.append(clockProbeMarker)
            try appendLengthPrefixed(JSONEncoder().encode(probe), to: &data)
        case .clockReply(let reply):
            data.append(clockReplyMarker)
            try appendLengthPrefixed(JSONEncoder().encode(reply), to: &data)
        }
        guard data.count <= maximumPacketLength else {
            throw CaptureTransportCodecError.packetTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CaptureTransportPacket {
        guard data.count <= maximumPacketLength, let marker = data.first else {
            throw CaptureTransportCodecError.malformedPacket
        }
        var reader = TransportReader(data: data.dropFirst())
        switch marker {
        case controlMarker:
            let payload = try reader.readLengthPrefixedData()
            guard reader.isAtEnd else { throw CaptureTransportCodecError.malformedPacket }
            return .control(try JSONDecoder().decode(CaptureMessageEnvelope.self, from: payload))
        case videoMarker:
            let headerData = try reader.readLengthPrefixedData()
            let header = try JSONDecoder().decode(CaptureVideoFrameHeader.self, from: headerData)
            let parameterSetCount = try reader.readByte()
            var parameterSets: [Data] = []
            parameterSets.reserveCapacity(Int(parameterSetCount))
            for _ in 0..<parameterSetCount {
                parameterSets.append(try reader.readLengthPrefixedData())
            }
            let encodedData = try reader.readLengthPrefixedData()
            guard reader.isAtEnd else { throw CaptureTransportCodecError.malformedPacket }
            return .video(
                CaptureEncodedVideoFrame(
                    header: header,
                    encodedData: encodedData,
                    parameterSets: parameterSets
                )
            )
        case poseMarker:
            let payload = try reader.readLengthPrefixedData()
            guard reader.isAtEnd else { throw CaptureTransportCodecError.malformedPacket }
            return .pose(try JSONDecoder().decode(CapturePosePacket.self, from: payload))
        case clockProbeMarker:
            let payload = try reader.readLengthPrefixedData()
            guard reader.isAtEnd else { throw CaptureTransportCodecError.malformedPacket }
            return .clockProbe(try JSONDecoder().decode(CaptureClockProbe.self, from: payload))
        case clockReplyMarker:
            let payload = try reader.readLengthPrefixedData()
            guard reader.isAtEnd else { throw CaptureTransportCodecError.malformedPacket }
            return .clockReply(try JSONDecoder().decode(CaptureClockReply.self, from: payload))
        default:
            throw CaptureTransportCodecError.malformedPacket
        }
    }

    private static func appendLengthPrefixed(_ payload: Data, to data: inout Data) throws {
        guard payload.count <= maximumPacketLength, payload.count <= Int(UInt32.max) else {
            throw CaptureTransportCodecError.packetTooLarge
        }
        data.appendUInt32(UInt32(payload.count))
        data.append(payload)
    }
}

/// Four-byte framing around encrypted transport packets sent on a reliable byte
/// stream. This frame is not a security boundary; AES-GCM is the boundary.
public enum CaptureTransportStreamCodec {
    public static let headerLength = 4

    public static func encode(_ packet: Data) throws -> Data {
        guard packet.count <= CaptureTransportPacketCodec.maximumPacketLength,
              packet.count <= Int(UInt32.max) else {
            throw CaptureTransportCodecError.packetTooLarge
        }
        var result = Data()
        result.appendUInt32(UInt32(packet.count))
        result.append(packet)
        return result
    }
}

public struct CaptureTransportStreamDecoder: Sendable {
    private var bufferedData = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        bufferedData.append(data)
        var packets: [Data] = []
        while bufferedData.count >= CaptureTransportStreamCodec.headerLength {
            let length = bufferedData.prefix(CaptureTransportStreamCodec.headerLength).uint32BigEndian
            guard length <= CaptureTransportPacketCodec.maximumPacketLength else {
                bufferedData.removeAll(keepingCapacity: false)
                throw CaptureTransportCodecError.packetTooLarge
            }
            let frameLength = CaptureTransportStreamCodec.headerLength + length
            guard bufferedData.count >= frameLength else { break }
            packets.append(Data(bufferedData.dropFirst(CaptureTransportStreamCodec.headerLength).prefix(length)))
            bufferedData.removeFirst(frameLength)
        }
        return packets
    }
}

private struct TransportReader {
    private let data: Data
    private var offset: Data.Index

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.endIndex else { throw CaptureTransportCodecError.malformedPacket }
        defer { offset = data.index(after: offset) }
        return data[offset]
    }

    mutating func readLengthPrefixedData() throws -> Data {
        guard data.distance(from: offset, to: data.endIndex) >= 4 else {
            throw CaptureTransportCodecError.malformedPacket
        }
        let headerEnd = data.index(offset, offsetBy: 4)
        let length = data[offset..<headerEnd].uint32BigEndian
        offset = headerEnd
        guard length <= CaptureTransportPacketCodec.maximumPacketLength,
              data.distance(from: offset, to: data.endIndex) >= length else {
            throw CaptureTransportCodecError.malformedPacket
        }
        let payloadEnd = data.index(offset, offsetBy: length)
        defer { offset = payloadEnd }
        return Data(data[offset..<payloadEnd])
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: 4))
    }
}

private extension Data.SubSequence {
    var uint32BigEndian: Int {
        reduce(0) { partial, byte in (partial << 8) | Int(byte) }
    }
}
