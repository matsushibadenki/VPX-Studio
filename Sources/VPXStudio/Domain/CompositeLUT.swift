import CryptoKit
import Foundation

/// A .cube 3D LUT for the linear Rec.709 composite. Red varies fastest.
struct CompositeLUT: Sendable {
    struct Reference: Codable, Hashable, Sendable {
        let name: String
        let sha256: String

        var isValid: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 256 &&
                name.rangeOfCharacter(from: .controlCharacters) == nil &&
                sha256.count == 64 && sha256.allSatisfy { "0123456789abcdef".contains($0) }
        }
    }

    struct Usage: Codable, Hashable, Sendable {
        let reference: Reference?
        let applied: Bool

        var isValid: Bool { reference?.isValid ?? !applied }
    }

    static let maximumFileSize = 8 * 1024 * 1024
    static let takeAssetPath = "look.cube"

    let originalBytes: Data
    let reference: Reference
    let size: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    let texels: [SIMD4<Float16>]

    static func load(_ url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        return try parse(bytes, name: url.lastPathComponent)
    }

    static func parse(_ bytes: Data, name: String) throws -> Self {
        guard bytes.count <= maximumFileSize, let contents = String(data: bytes, encoding: .utf8) else {
            throw StudioAssetError.invalid("3D LUT file")
        }
        let reference = Reference(name: name,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        guard reference.isValid else { throw StudioAssetError.invalid("3D LUT name") }
        var size: Int?
        var low = SIMD3<Float>(repeating: 0)
        var high = SIMD3<Float>(repeating: 1)
        var domains = Set<Substring>()
        var texels: [SIMD4<Float16>] = []
        func triple(_ tokens: ArraySlice<Substring>) throws -> SIMD3<Float> {
            let values = tokens.compactMap { Float($0) }
            guard tokens.count == 3, values.count == 3, values.allSatisfy(\.isFinite) else {
                throw StudioAssetError.invalid("3D LUT RGB values")
            }
            return SIMD3(values[0], values[1], values[2])
        }
        for line in contents.split(whereSeparator: \.isNewline) {
            let uncommented = line.prefix { $0 != "#" }
            let fields = uncommented.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            switch first {
            case "TITLE":
                guard texels.isEmpty else { throw StudioAssetError.invalid("3D LUT title") }
            case "LUT_3D_SIZE":
                guard size == nil, fields.count == 2, let side = Int(fields[1]), (2...65).contains(side) else {
                    throw StudioAssetError.invalid("3D LUT size")
                }
                size = side
                texels.reserveCapacity(side * side * side)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard texels.isEmpty, domains.insert(first).inserted else {
                    throw StudioAssetError.invalid("3D LUT domain")
                }
                let domain = try triple(fields.dropFirst())
                if first == "DOMAIN_MIN" { low = domain } else { high = domain }
            default:
                guard let size, texels.count < size * size * size else {
                    throw StudioAssetError.invalid("3D LUT sample count")
                }
                let rgb = try triple(fields[...])
                let texel = SIMD4<Float16>(Float16(rgb.x), Float16(rgb.y), Float16(rgb.z), 1)
                guard texel.x.isFinite, texel.y.isFinite, texel.z.isFinite else {
                    throw StudioAssetError.invalid("3D LUT sample range")
                }
                texels.append(texel)
            }
        }
        let extent = high - low
        guard let size, texels.count == size * size * size,
              [extent.x, extent.y, extent.z].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw StudioAssetError.invalid("3D LUT samples or domain")
        }
        return Self(originalBytes: bytes, reference: reference, size: size, domainMin: low, domainMax: high, texels: texels)
    }
}
