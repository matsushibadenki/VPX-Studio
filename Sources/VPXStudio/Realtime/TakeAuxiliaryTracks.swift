import CoreMedia
import Metal
import Foundation
import simd

struct TakeAuxiliaryFrame: Sendable {
    struct Pose: Codable, Sendable {
        let worldFromCamera: [Float]
        let mode: String
        let horizonMilliseconds: Double

        init(_ resolved: PoseTimeline.Resolved) {
            let matrix = resolved.transform
            worldFromCamera = (0..<4).flatMap { [matrix[$0].x, matrix[$0].y, matrix[$0].z, matrix[$0].w] }
            mode = resolved.mode.rawValue
            horizonMilliseconds = resolved.horizonMilliseconds
        }
    }

    let sourceID: UUID?
    let inputSequence: UInt64?
    let inputHostSeconds: Double?
    let depth: DepthPreviewInput?
    let pose: Pose?
}

struct TakeMatteCopy: @unchecked Sendable {
    // The dedicated shared buffer is read only after its Metal command completes.
    let buffer: MTLBuffer
    let bytesPerRow: Int
    let width: Int
    let height: Int
}

/// Owned by the recorder's serial queue. One row per successfully written video sample.
final class TakeAuxiliaryTracks {
    struct Range: Codable, Sendable {
        let offset: UInt64
        let length: Int
    }

    struct Depth: Codable, Sendable {
        let width: UInt32
        let height: UInt32
        let sequence: UInt64
        let capturedHostSeconds: Double
        let values: Range
        let confidence: Range
    }

    struct Row: Codable, Sendable {
        let frameIndex: Int
        let ptsValue: Int64
        let ptsTimescale: Int32
        let sourceID: UUID?
        let inputSequence: UInt64?
        let inputHostSeconds: Double?
        let matte: Range?
        let matteWidth: Int?
        let matteHeight: Int?
        let depth: Depth?
        let pose: TakeAuxiliaryFrame.Pose?
    }

    private let directory: URL
    private let encoder = JSONEncoder()
    private var handles: [String: FileHandle] = [:]
    private var latestDepth: (DepthPreviewInput, Depth)?

    init(directory: URL) { self.directory = directory }

    private func write(_ data: Data, to name: String) throws -> Range {
        let handle: FileHandle
        if let existing = handles[name] {
            handle = existing
        } else {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url, options: .withoutOverwriting)
            handle = try FileHandle(forWritingTo: url)
            handles[name] = handle
        }
        let offset = try handle.offset()
        try handle.write(contentsOf: data)
        return Range(offset: offset, length: data.count)
    }

    func append(frame: TakeAuxiliaryFrame?, matte: TakeMatteCopy?, index: Int, time: CMTime) throws {
        var matteRange: Range?
        if let matte {
            let stride = matte.width * 2
            var pixels = Data(count: stride * matte.height)
            pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                guard let base = target.baseAddress else { return }
                for row in 0..<matte.height {
                    base.advanced(by: row * stride).copyMemory(
                        from: matte.buffer.contents().advanced(by: row * matte.bytesPerRow), byteCount: stride)
                }
            }
            matteRange = try write(pixels, to: "matte.f16le")
        }

        var depth: Depth?
        if let input = frame?.depth {
            if let (previous, reference) = latestDepth,
               previous.sourceID == input.sourceID, previous.capturedHostSeconds == input.capturedHostSeconds,
               previous.packet.header.sequence == input.packet.header.sequence {
                depth = reference
            } else {
                let packet = input.packet
                let values = try write(packet.depth, to: "depth.bin")
                let confidence = try write(packet.confidence, to: "depth.bin")
                let reference = Depth(width: packet.header.width, height: packet.header.height,
                    sequence: packet.header.sequence, capturedHostSeconds: input.capturedHostSeconds,
                    values: values, confidence: confidence)
                latestDepth = (input, reference)
                depth = reference
            }
        }
        let row = Row(frameIndex: index, ptsValue: time.value, ptsTimescale: time.timescale,
            sourceID: frame?.sourceID, inputSequence: frame?.inputSequence, inputHostSeconds: frame?.inputHostSeconds,
            matte: matteRange, matteWidth: matte?.width, matteHeight: matte?.height, depth: depth, pose: frame?.pose)
        var line = try encoder.encode(row)
        line.append(0x0A)
        _ = try write(line, to: "frames.jsonl")
    }

    func close() throws -> [TakeManifest.Asset] {
        for handle in handles.values { try handle.close() }
        let paths = Set(handles.keys)
        handles.removeAll()
        let assets: [TakeManifest.Asset] = [
            .init(role: .pose, relativePath: "frames.jsonl"),
            .init(role: .matte, relativePath: "matte.f16le"),
            .init(role: .depth, relativePath: "depth.bin")
        ]
        return assets.filter { paths.contains($0.relativePath) }
    }
}
