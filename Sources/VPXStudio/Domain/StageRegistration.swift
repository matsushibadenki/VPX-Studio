import Foundation
import simd

/// A manually confirmed camera pose anchors one Node world to Stage space.
/// Connection identity prevents reuse after an ARSession/world restart.
struct StageRegistration: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let nodeID: UUID
    let connectionID: UUID
    let referenceSpaceRevision: UInt64
    let anchoredAt: Date
    let stageFromNodeWorld: [Float]

    static func anchor(nodeID: UUID, connectionID: UUID, referenceSpaceRevision: UInt64,
                       stageFromCamera: simd_float4x4, nodeWorldFromCamera: simd_float4x4,
                       now: Date) throws -> Self {
        try validateRigid(stageFromCamera)
        try validateRigid(nodeWorldFromCamera)
        let matrix = stageFromCamera * simd_inverse(nodeWorldFromCamera)
        let result = Self(nodeID: nodeID, connectionID: connectionID,
            referenceSpaceRevision: referenceSpaceRevision, anchoredAt: now,
            stageFromNodeWorld: (0..<4).flatMap { [matrix[$0].x, matrix[$0].y, matrix[$0].z, matrix[$0].w] })
        try result.validate()
        return result
    }

    func validate() throws {
        guard schemaVersion == 1, stageFromNodeWorld.count == 16,
              anchoredAt.timeIntervalSince1970.isFinite else { throw StudioAssetError.invalid("stage registration") }
        try Self.validateRigid(transform)
    }

    var transform: simd_float4x4 {
        guard stageFromNodeWorld.count == 16 else { return matrix_identity_float4x4 }
        let v = stageFromNodeWorld
        return simd_float4x4(columns: (SIMD4(v[0],v[1],v[2],v[3]), SIMD4(v[4],v[5],v[6],v[7]),
            SIMD4(v[8],v[9],v[10],v[11]), SIMD4(v[12],v[13],v[14],v[15])))
    }

    func matches(nodeID: UUID, connectionID: UUID?, referenceSpaceRevision: UInt64?) -> Bool {
        self.nodeID == nodeID && self.connectionID == connectionID && self.referenceSpaceRevision == referenceSpaceRevision
    }

    static func validateRigid(_ matrix: simd_float4x4) throws {
        let columns = (0..<4).map { matrix[$0] }
        let axes = (0..<3).map { SIMD3(matrix[$0].x, matrix[$0].y, matrix[$0].z) }
        guard columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }),
              abs(matrix[3].x) <= 100_000, abs(matrix[3].y) <= 100_000, abs(matrix[3].z) <= 100_000,
              abs(matrix[0].w) < 0.0001, abs(matrix[1].w) < 0.0001, abs(matrix[2].w) < 0.0001,
              abs(matrix[3].w-1) < 0.0001,
              axes.allSatisfy({ abs(simd_length($0)-1) < 0.001 }),
              abs(simd_dot(axes[0],axes[1])) < 0.001, abs(simd_dot(axes[0],axes[2])) < 0.001,
              abs(simd_dot(axes[1],axes[2])) < 0.001, abs(simd_determinant(matrix)-1) < 0.001 else {
            throw StudioAssetError.invalid("non-rigid stage registration")
        }
    }
}

enum StageAnchorTiming {
    static func accepts(videoHostSeconds: Double?, poseHostNanoseconds: Double?, now: UInt64) -> Bool {
        guard let video = videoHostSeconds, let poseNS = poseHostNanoseconds,
              video.isFinite, poseNS.isFinite else { return false }
        let pose = poseNS / 1_000_000_000
        let current = Double(now) / 1_000_000_000
        return current-video >= 0 && current-video <= 0.15 && current-pose >= 0 && current-pose <= 0.15 && abs(video-pose) <= 0.05
    }
}
