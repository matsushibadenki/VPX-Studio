import CoreVideo
import Foundation

struct TakeSourceFrame: @unchecked Sendable {
    static let path = "source-frames.bin"
    // The buffer belongs to the captured frame and is only read by the writer.
    let buffer: CVPixelBuffer
    let color: VideoColorMetadata

    struct Index: Codable, Sendable {
        let width: Int
        let height: Int
        let format: UInt32
        let color: VideoColorMetadata
        let range: TakeAuxiliaryTracks.Range
    }

    struct Layout {
        let rowBytes: Int
        let rows: Int
    }

    static func layout(width: Int, height: Int, format: UInt32) throws -> [Layout] {
        guard (1...8192).contains(width), (1...8192).contains(height) else {
            throw StudioAssetError.invalid("Take source dimensions")
        }
        if format == kCVPixelFormatType_32BGRA { return [.init(rowBytes: width * 4, rows: height)] }
        let bytes: Int
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: bytes = 1
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: bytes = 2
        default: throw StudioAssetError.unsupported("Take source pixel format")
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw StudioAssetError.invalid("Take source plane dimensions")
        }
        return [.init(rowBytes: width * bytes, rows: height), .init(rowBytes: width * bytes, rows: height / 2)]
    }

    private static func access(_ buffer: CVPixelBuffer, layout: [Layout], flags: CVPixelBufferLockFlags,
                               body: (UnsafeMutableRawPointer, Int) -> Void) throws {
        guard CVPixelBufferLockBaseAddress(buffer, flags) == kCVReturnSuccess else {
            throw StudioAssetError.invalid("Take source buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, flags) }
        for (index, plane) in layout.enumerated() {
            let planar = layout.count > 1
            let address = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
            guard let address, stride >= plane.rowBytes else { throw StudioAssetError.invalid("Take source stride") }
            for row in 0..<plane.rows { body(address.advanced(by: row * stride), plane.rowBytes) }
        }
    }

    func encoded(write: (Data) throws -> TakeAuxiliaryTracks.Range) throws -> Index {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let layout = try Self.layout(width: width, height: height, format: format)
        var data = Data()
        data.reserveCapacity(layout.reduce(0) { $0 + $1.rowBytes * $1.rows })
        try Self.access(buffer, layout: layout, flags: .readOnly) { row, count in
            data.append(row.assumingMemoryBound(to: UInt8.self), count: count)
        }
        return Index(width: width, height: height, format: format, color: color, range: try write(data))
    }

    static func decode(_ index: Index, data: Data) throws -> Self {
        let layout = try layout(width: index.width, height: index.height, format: index.format)
        guard data.count == layout.reduce(0, { $0 + $1.rowBytes * $1.rows }) else {
            throw StudioAssetError.invalid("Take source byte count")
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, index.width, index.height, index.format, attributes, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw StudioAssetError.invalid("Take source buffer allocation") }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { throw StudioAssetError.invalid("Take source bytes") }
            var offset = 0
            try access(pixelBuffer, layout: layout, flags: []) { row, count in
                row.copyMemory(from: base.advanced(by: offset), byteCount: count)
                offset += count
            }
        }
        return .init(buffer: pixelBuffer, color: index.color)
    }
}
