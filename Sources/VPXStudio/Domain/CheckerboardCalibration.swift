import Foundation
import simd

struct CheckerboardObservation: Codable, Sendable {
    struct Point: Codable, Hashable, Sendable { var x: Double; var y: Double }
    var schemaVersion = 1
    var cameraID: UUID
    var lensID: String
    var imageWidth: Int
    var imageHeight: Int
    var columns: Int
    var rows: Int
    var squareSizeMeters: Double
    /// Inner corners, row-major, first row at board +Y. Board origin is center.
    var imagePoints: [Point]
    var stageFromBoard: [Float]
    var measuredAt: Date
    var expiresAt: Date
    var focusDistanceMeters: Float?

    func validate(now: Date) throws {
        guard schemaVersion == 1, (3...20).contains(columns), (3...20).contains(rows),
              imageWidth > 0, imageWidth <= 16384, imageHeight > 0, imageHeight <= 16384,
              squareSizeMeters.isFinite, (0.001...1).contains(squareSizeMeters),
              Double(max(columns,rows)-1)*squareSizeMeters <= 10,
              !lensID.isEmpty, lensID.count <= 256, imagePoints.count == columns*rows,
              imagePoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                  $0.x < Double(imageWidth) && $0.y < Double(imageHeight) }),
              measuredAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              measuredAt <= now, now < expiresAt, expiresAt > measuredAt,
              stageFromBoard.count == 16 else { throw CheckerboardError.invalidObservation }
        try StageRegistration.validateRigid(boardTransform)
        let x = imagePoints.map(\.x), y = imagePoints.map(\.y)
        guard (x.max()! - x.min()!) >= 20, (y.max()! - y.min()!) >= 20 else { throw CheckerboardError.degenerate }
        let mx = x.reduce(0,+)/Double(x.count), my = y.reduce(0,+)/Double(y.count)
        let xx = x.reduce(0) { $0+($1-mx)*($1-mx) }, yy = y.reduce(0) { $0+($1-my)*($1-my) }
        let xy = zip(x,y).reduce(0) { $0+($1.0-mx)*($1.1-my) }
        guard xx*yy-xy*xy > (xx+yy)*(xx+yy)*1e-4, Set(imagePoints).count == imagePoints.count else {
            throw CheckerboardError.degenerate
        }
        if let focusDistanceMeters {
            guard focusDistanceMeters.isFinite, focusDistanceMeters > 0 else { throw CheckerboardError.invalidObservation }
        }
    }

    var boardTransform: simd_float4x4 {
        guard stageFromBoard.count == 16 else { return matrix_identity_float4x4 }
        let v = stageFromBoard
        return simd_float4x4(columns: (SIMD4(v[0],v[1],v[2],v[3]),SIMD4(v[4],v[5],v[6],v[7]),
            SIMD4(v[8],v[9],v[10],v[11]),SIMD4(v[12],v[13],v[14],v[15])))
    }

    var objectPoints: [SIMD3<Double>] {
        (0..<rows).flatMap { row in (0..<columns).map { column in
            SIMD3((Double(column)-Double(columns-1)/2)*squareSizeMeters,
                (Double(rows-1)/2-Double(row))*squareSizeMeters,0)
        } }
    }

    static func load(_ url: URL) throws -> Self {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw CheckerboardError.invalidObservation }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw CheckerboardError.invalidObservation }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self,from: data)
    }
}

enum CheckerboardError: Error {
    case invalidObservation, intrinsicsMismatch, intrinsicsExpired, degenerate, excessiveResidual
    var localizationKey: LocalizationKey {
        switch self {
        case .invalidObservation: .checkerboardInvalid
        case .intrinsicsMismatch: .checkerboardIntrinsicsMismatch
        case .intrinsicsExpired: .checkerboardIntrinsicsExpired
        case .degenerate: .checkerboardDegenerate
        case .excessiveResidual: .checkerboardResidualRejected
        }
    }
}

struct CheckerboardMeasurement: Codable, Equatable, Sendable {
    let method: String
    let columns: Int
    let rows: Int
    let squareSizeMeters: Double
    let maximumResidualPixels: Double
    let optimizationIterations: Int
    let stageFromBoard: [Float]
    let imagePoints: [CheckerboardObservation.Point]
    let focusDistanceMeters: Float?
}

struct CheckerboardSolution: Sendable {
    let camera: CameraCalibration
    let rmsePixels: Double
    let measurement: CheckerboardMeasurement
}

enum CheckerboardSolver {
    private struct Pose {
        var rotation: simd_double3x3
        var translation: SIMD3<Double>
        var matrix: simd_double4x4 {
            simd_double4x4(columns: (SIMD4(rotation[0],0),SIMD4(rotation[1],0),SIMD4(rotation[2],0),SIMD4(translation,1)))
        }
        func shifted(_ delta: [Double], scale: Double = 1) -> Self {
            let w = SIMD3(delta[3],delta[4],delta[5])*scale
            let angle = simd_length(w)
            let r = angle > 1e-12 ? simd_double3x3(simd_quatd(angle: angle,axis: w/angle)) : matrix_identity_double3x3
            return Pose(rotation: r*rotation,translation: r*translation+SIMD3(delta[0],delta[1],delta[2])*scale)
        }
    }

    static func solve(_ observation: CheckerboardObservation, intrinsics: CameraCalibration, now: Date) throws -> CheckerboardSolution {
        try Task.checkCancellation()
        try observation.validate(now: now); try intrinsics.validate()
        guard Float(observation.imageWidth) == intrinsics.imageWidth, Float(observation.imageHeight) == intrinsics.imageHeight else {
            throw CheckerboardError.intrinsicsMismatch
        }
        var projection = intrinsics
        if let first = intrinsics.breathing.first, let last = intrinsics.breathing.last {
            guard let focus = observation.focusDistanceMeters, focus >= first.focusMeters, focus <= last.focusMeters else {
                throw CheckerboardError.intrinsicsMismatch
            }
            let factor = intrinsics.focalLength(at: focus,fallback: intrinsics.referenceFocalLengthMillimeters)/intrinsics.referenceFocalLengthMillimeters
            projection.fx *= factor; projection.fy *= factor
            try projection.validate()
        }
        let objects = observation.objectPoints
        let normalized = try observation.imagePoints.map { try undistort($0, camera: projection) }
        let scale = Double(max(observation.columns,observation.rows)-1)*observation.squareSizeMeters
        var a = [[Double]](), b = [Double]()
        for i in objects.indices {
            let x = objects[i].x/scale, y = objects[i].y/scale, u = normalized[i].x, v = normalized[i].y
            a.append([x,y,1,0,0,0,-u*x,-u*y]); b.append(u)
            a.append([0,0,0,x,y,1,-v*x,-v*y]); b.append(v)
        }
        let h = try leastSquares(a,b)
        let c1 = SIMD3(h[0],h[3],h[6])/scale, c2 = SIMD3(h[1],h[4],h[7])/scale
        let c3 = SIMD3(h[2],h[5],1)
        let magnitude = (simd_length(c1)+simd_length(c2))/2
        guard magnitude.isFinite, magnitude > 1e-9 else { throw CheckerboardError.degenerate }
        let r1 = simd_normalize(c1)
        let perpendicular = c2-simd_dot(c2,r1)*r1
        guard simd_length(perpendicular) > 1e-9 else { throw CheckerboardError.degenerate }
        let r2 = simd_normalize(perpendicular)
        var pose = Pose(rotation: simd_double3x3(columns: (r1,r2,simd_cross(r1,r2))),translation: c3/magnitude)
        var iterations = 0
        // Refine a rigid pose against distorted image pixels, not just the
        // unconstrained planar homography. Small damped steps reduce residual.
        for _ in 0..<30 {
            try Task.checkCancellation()
            let residual = try residuals(pose,objects: objects,observed: observation.imagePoints,camera: projection)
            let cost = residual.reduce(0) { $0+$1*$1 }
            var jacobian = Array(repeating: Array(repeating: 0.0,count: 6),count: residual.count)
            for parameter in 0..<6 {
                let epsilon = parameter < 3 ? 1e-5 : 1e-6
                var delta = [Double](repeating: 0,count: 6); delta[parameter] = epsilon
                let perturbed = try residuals(pose.shifted(delta),objects: objects,observed: observation.imagePoints,camera: projection)
                for row in residual.indices { jacobian[row][parameter] = (perturbed[row]-residual[row])/epsilon }
            }
            let delta = try leastSquares(jacobian,residual.map { -$0 }, damping: 1e-6)
            var improved = false
            for fraction in [1.0,0.5,0.25,0.125,0.0625] {
                let candidate = pose.shifted(delta,scale: fraction)
                if let values = try? residuals(candidate,objects: objects,observed: observation.imagePoints,camera: projection),
                   values.reduce(0,{ $0+$1*$1 }) < cost {
                    pose = candidate; improved = true; iterations += 1; break
                }
            }
            if !improved || delta.reduce(0,{ $0+$1*$1 }) < 1e-16 { break }
        }
        let errors = try residuals(pose,objects: objects,observed: observation.imagePoints,camera: projection)
        let rmse = sqrt(errors.reduce(0) { $0+$1*$1 }/Double(objects.count))
        let maximum = stride(from: 0,to: errors.count,by: 2).map { hypot(errors[$0],errors[$0+1]) }.max() ?? .infinity
        guard rmse.isFinite, rmse <= 2, maximum <= 5 else { throw CheckerboardError.excessiveResidual }
        // Optical CV camera: +Y down/+Z forward -> VPX: +Y up/-Z forward.
        let cameraConvention = simd_double4x4(diagonal: SIMD4(1,-1,-1,1))
        let board = observation.boardTransform
        let doubleBoard = simd_double4x4((0..<4).map { SIMD4<Double>(Double(board[$0].x),Double(board[$0].y),Double(board[$0].z),Double(board[$0].w)) })
        let stage = doubleBoard * simd_inverse(cameraConvention*pose.matrix)
        let result = simd_float4x4((0..<4).map { SIMD4<Float>(Float(stage[$0].x),Float(stage[$0].y),Float(stage[$0].z),Float(stage[$0].w)) })
        try StageRegistration.validateRigid(result)
        let stored = simd_double4x4((0..<4).map { SIMD4<Double>(Double(result[$0].x),Double(result[$0].y),Double(result[$0].z),Double(result[$0].w)) })
        let storedCV = cameraConvention*simd_inverse(stored)*doubleBoard
        let storedPose = Pose(rotation: simd_double3x3(columns: (SIMD3(storedCV[0].x,storedCV[0].y,storedCV[0].z),
            SIMD3(storedCV[1].x,storedCV[1].y,storedCV[1].z),SIMD3(storedCV[2].x,storedCV[2].y,storedCV[2].z))),
            translation: SIMD3(storedCV[3].x,storedCV[3].y,storedCV[3].z))
        let storedErrors = try residuals(storedPose,objects: objects,observed: observation.imagePoints,camera: projection)
        let storedRMSE = sqrt(storedErrors.reduce(0) { $0+$1*$1 }/Double(objects.count))
        let storedMaximum = stride(from: 0,to: storedErrors.count,by: 2).map { hypot(storedErrors[$0],storedErrors[$0+1]) }.max() ?? .infinity
        guard storedRMSE.isFinite, storedRMSE <= 2, storedMaximum <= 5 else { throw CheckerboardError.excessiveResidual }
        var camera = intrinsics
        camera.worldFromCamera = (0..<4).flatMap { [result[$0].x,result[$0].y,result[$0].z,result[$0].w] }
        // Measuring extrinsics does not promote estimated intrinsics to measured.
        try camera.validate()
        return CheckerboardSolution(camera: camera,rmsePixels: storedRMSE,
            measurement: .init(method: "checkerboard-planar-v1",columns: observation.columns,rows: observation.rows,
                squareSizeMeters: observation.squareSizeMeters,maximumResidualPixels: storedMaximum,optimizationIterations: iterations,
                stageFromBoard: observation.stageFromBoard,imagePoints: observation.imagePoints,focusDistanceMeters: observation.focusDistanceMeters))
    }

    private static func distort(_ p: SIMD2<Double>, camera c: CameraCalibration) -> SIMD2<Double> {
        let x = p.x, y = p.y, r2 = simd_dot(p,p)
        let radial = 1+Double(c.k1)*r2+Double(c.k2)*r2*r2+Double(c.k3)*r2*r2*r2
        return SIMD2(x*radial+2*Double(c.p1)*x*y+Double(c.p2)*(r2+2*x*x),
            y*radial+Double(c.p1)*(r2+2*y*y)+2*Double(c.p2)*x*y)
    }

    private static func undistort(_ pixel: CheckerboardObservation.Point, camera c: CameraCalibration) throws -> SIMD2<Double> {
        let target = SIMD2((pixel.x-Double(c.cx))/Double(c.fx),(pixel.y-Double(c.cy))/Double(c.fy))
        var p = target
        for _ in 0..<30 {
            let error = distort(p,camera: c)-target
            if simd_length(error) < 1e-10 { return p }
            let epsilon = 1e-6
            let dx = (distort(p+SIMD2(epsilon,0),camera: c)-distort(p,camera: c))/epsilon
            let dy = (distort(p+SIMD2(0,epsilon),camera: c)-distort(p,camera: c))/epsilon
            let determinant = dx.x*dy.y-dy.x*dx.y
            guard determinant.isFinite, abs(determinant) > 1e-12 else { throw CheckerboardError.degenerate }
            p -= SIMD2((dy.y*error.x-dy.x*error.y)/determinant,(-dx.y*error.x+dx.x*error.y)/determinant)
            guard p.x.isFinite, p.y.isFinite, simd_length(p) < 10 else { throw CheckerboardError.degenerate }
        }
        throw CheckerboardError.degenerate
    }

    private static func residuals(_ pose: Pose, objects: [SIMD3<Double>], observed: [CheckerboardObservation.Point],
                                  camera c: CameraCalibration) throws -> [Double] {
        var values = [Double](); values.reserveCapacity(objects.count*2)
        for i in objects.indices {
            let point = pose.rotation*objects[i]+pose.translation
            guard point.z > 0.01, point.z.isFinite else { throw CheckerboardError.degenerate }
            let image = distort(SIMD2(point.x/point.z,point.y/point.z),camera: c)
            let u = Double(c.fx)*image.x+Double(c.cx), v = Double(c.fy)*image.y+Double(c.cy)
            guard u.isFinite, v.isFinite else { throw CheckerboardError.degenerate }
            values.append(u-observed[i].x); values.append(v-observed[i].y)
        }
        return values
    }

    private static func leastSquares(_ a: [[Double]], _ b: [Double], damping: Double = 0) throws -> [Double] {
        guard let count = a.first?.count, a.count == b.count else { throw CheckerboardError.degenerate }
        var matrix = Array(repeating: Array(repeating: 0.0,count: count+1),count: count)
        for row in a.indices {
            for i in 0..<count {
                matrix[i][count] += a[row][i]*b[row]
                for j in 0..<count { matrix[i][j] += a[row][i]*a[row][j] }
            }
        }
        for i in 0..<count { matrix[i][i] += damping*max(1,matrix[i][i]) }
        let largest = matrix.flatMap { $0.prefix(count) }.map(abs).max() ?? 0
        for column in 0..<count {
            let pivot = (column..<count).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
            guard abs(matrix[pivot][column]) > max(1e-14,largest*1e-12) else { throw CheckerboardError.degenerate }
            matrix.swapAt(column,pivot)
            let divisor = matrix[column][column]
            for j in column...count { matrix[column][j] /= divisor }
            for row in 0..<count where row != column {
                let multiplier = matrix[row][column]
                for j in column...count { matrix[row][j] -= multiplier*matrix[column][j] }
            }
        }
        let result = matrix.map { $0[count] }
        guard result.allSatisfy(\.isFinite) else { throw CheckerboardError.degenerate }
        return result
    }
}
