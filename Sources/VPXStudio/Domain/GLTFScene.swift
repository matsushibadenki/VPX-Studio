import Foundation
import simd

struct SceneVertex: Sendable {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
}
struct SceneMaterial: Sendable {
    var baseColor = SIMD4<Float>(0.12, 0.35, 0.75, 1)
    var metallic: Float = 0
    var roughness: Float = 0.5
}
struct SceneMesh: Sendable { var vertices: [SceneVertex]; var material: SceneMaterial }
struct StudioScene: Sendable {
    var id = UUID()
    var name: String
    var meshes: [SceneMesh]
    var lightDirection = simd_normalize(SIMD3<Float>(-0.5, 1, 0.7))
    var lightColor = SIMD3<Float>(repeating: 1)
    var lightIntensity: Float = 3
    var cameraWorldTransform = matrix_identity_float4x4

    static var demo: Self {
        let corners: [[SIMD3<Float>]] = [
            [SIMD3(-1,-1,1),SIMD3(1,-1,1),SIMD3(1,1,1),SIMD3(-1,1,1)],
            [SIMD3(1,-1,-1),SIMD3(-1,-1,-1),SIMD3(-1,1,-1),SIMD3(1,1,-1)],
            [SIMD3(-1,-1,-1),SIMD3(-1,-1,1),SIMD3(-1,1,1),SIMD3(-1,1,-1)],
            [SIMD3(1,-1,1),SIMD3(1,-1,-1),SIMD3(1,1,-1),SIMD3(1,1,1)],
            [SIMD3(-1,1,1),SIMD3(1,1,1),SIMD3(1,1,-1),SIMD3(-1,1,-1)],
            [SIMD3(-1,-1,-1),SIMD3(1,-1,-1),SIMD3(1,-1,1),SIMD3(-1,-1,1)]]
        var vertices: [SceneVertex] = []
        for face in corners {
            let normal = simd_normalize(simd_cross(face[1]-face[0], face[2]-face[0]))
            for index in [0,1,2,0,2,3] {
                vertices.append(.init(position: SIMD4(face[index]*0.6 + SIMD3(0,0,-4),1), normal: SIMD4(normal,0)))
            }
        }
        let ground = [SIMD3<Float>(-4,-0.6,-1),SIMD3(4,-0.6,-1),SIMD3(4,-0.6,-9),SIMD3(-4,-0.6,-9)]
        let floor = [0,1,2,0,2,3].map { SceneVertex(position: SIMD4(ground[$0],1), normal: SIMD4(0,1,0,0)) }
        return StudioScene(name: "VPX Demo", meshes: [.init(vertices: vertices, material: .init()),
            .init(vertices: floor, material: .init(baseColor: SIMD4(0.3,0.3,0.3,1), metallic: 0, roughness: 0.8))])
    }
}

/// glTF 2.0 static, opaque, untextured TRIANGLES subset. Unsupported features fail explicitly.
enum GLTFSceneLoader {
    private struct Marker: Decodable {}
    private struct Asset: Decodable { let version: String }
    private struct Buffer: Decodable { let uri: String; let byteLength: Int }
    private struct View: Decodable { let buffer: Int; let byteOffset: Int?; let byteLength: Int; let byteStride: Int? }
    private struct Accessor: Decodable {
        let bufferView: Int?; let byteOffset: Int?; let componentType: Int; let count: Int; let type: String
        let sparse: Marker?; let normalized: Bool?
    }
    private struct PBR: Decodable {
        let baseColorFactor: [Float]?; let metallicFactor: Float?; let roughnessFactor: Float?
        let baseColorTexture: Marker?; let metallicRoughnessTexture: Marker?
    }
    private struct Material: Decodable {
        let pbrMetallicRoughness: PBR?; let alphaMode: String?
        let normalTexture: Marker?; let emissiveTexture: Marker?; let occlusionTexture: Marker?
        let emissiveFactor: [Float]?; let extensions: Marker?
        let doubleSided: Bool?
    }
    private struct Primitive: Decodable { let attributes: [String:Int]; let indices: Int?; let material: Int?; let mode: Int?; let targets: [Marker]? }
    private struct Mesh: Decodable { let primitives: [Primitive] }
    private struct LightReference: Decodable { let light: Int }
    private struct NodeExtensions: Decodable { let KHR_lights_punctual: LightReference? }
    private struct Node: Decodable {
        let mesh: Int?; let children: [Int]?; let matrix: [Float]?; let translation: [Float]?; let rotation: [Float]?; let scale: [Float]?
        let skin: Int?; let extensions: NodeExtensions?
    }
    private struct Scene: Decodable { let nodes: [Int]? }
    private struct Light: Decodable { let type: String; let color: [Float]?; let intensity: Float? }
    private struct Lights: Decodable { let lights: [Light] }
    private struct Extensions: Decodable { let KHR_lights_punctual: Lights? }
    private struct Document: Decodable {
        let asset: Asset; let buffers: [Buffer]?; let bufferViews: [View]?; let accessors: [Accessor]?
        let meshes: [Mesh]?; let nodes: [Node]?; let scenes: [Scene]?; let scene: Int?; let materials: [Material]?
        let animations: [Marker]?; let skins: [Marker]?; let textures: [Marker]?; let extensionsRequired: [String]?
        let extensions: Extensions?
    }

    static func load(_ url: URL) throws -> StudioScene {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64*1024*1024 else { throw StudioAssetError.invalid("glTF size limit") }
        return try load(data: Data(contentsOf: url), baseDirectory: url.deletingLastPathComponent(), name: url.lastPathComponent)
    }

    static func load(data: Data, baseDirectory: URL, name: String = "glTF") throws -> StudioScene {
        guard data.count <= 64*1024*1024 else { throw StudioAssetError.invalid("glTF size limit") }
        let doc = try JSONDecoder().decode(Document.self, from: data)
        guard doc.asset.version == "2.0", (doc.animations ?? []).isEmpty, (doc.skins ?? []).isEmpty,
              (doc.textures ?? []).isEmpty, (doc.extensionsRequired ?? []).allSatisfy({ $0 == "KHR_lights_punctual" }) else {
            throw StudioAssetError.unsupported("glTF version, animation, skin, texture or required extension")
        }
        let root = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        var totalBytes = 0
        let buffers = try (doc.buffers ?? []).map { buffer -> Data in
            guard buffer.byteLength >= 0, buffer.byteLength <= 128*1024*1024 else { throw StudioAssetError.invalid("buffer size") }
            totalBytes += buffer.byteLength
            guard totalBytes <= 256*1024*1024 else { throw StudioAssetError.invalid("total buffer size") }
            let content: Data
            if buffer.uri.hasPrefix("data:application/octet-stream;base64,") || buffer.uri.hasPrefix("data:application/gltf-buffer;base64,") {
                guard let comma = buffer.uri.firstIndex(of: ","), let decoded = Data(base64Encoded: String(buffer.uri[buffer.uri.index(after: comma)...])) else { throw StudioAssetError.invalid("base64") }
                content = decoded
            } else {
                guard let path = buffer.uri.removingPercentEncoding, !path.contains(":"), !path.hasPrefix("/"), !path.contains("\\") else { throw StudioAssetError.invalid("buffer URI") }
                let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard file.path.hasPrefix(root.path + "/"),
                      (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128*1024*1024 else { throw StudioAssetError.invalid("buffer path") }
                content = try Data(contentsOf: file)
            }
            guard content.count == buffer.byteLength else { throw StudioAssetError.invalid("buffer byteLength") }
            return content
        }
        func indexed<T>(_ list: [T]?, _ index: Int) throws -> T {
            guard let list, list.indices.contains(index) else { throw StudioAssetError.invalid("index \(index)") }
            return list[index]
        }
        func values(_ index: Int, vector: Bool) throws -> [Float] {
            let a = try indexed(doc.accessors, index)
            guard a.sparse == nil, a.normalized != true, a.count > 0, a.count <= 1_000_000,
                  a.type == (vector ? "VEC3" : "SCALAR"), vector ? a.componentType == 5126 : [5121,5123,5125].contains(a.componentType),
                  let vi = a.bufferView else { throw StudioAssetError.unsupported("accessor") }
            let view = try indexed(doc.bufferViews, vi)
            let buffer = try indexed(buffers, view.buffer)
            let componentSize = a.componentType == 5121 ? 1 : a.componentType == 5123 ? 2 : 4
            let elementSize = componentSize * (vector ? 3 : 1)
            let stride = view.byteStride ?? elementSize
            let offset = a.byteOffset ?? 0, base = view.byteOffset ?? 0
            guard stride >= elementSize, stride <= 1024, base >= 0, offset >= 0, view.byteLength >= 0,
                  base.isMultiple(of: componentSize), offset.isMultiple(of: componentSize),
                  view.byteStride == nil || stride >= 4 && stride <= 252 && stride.isMultiple(of: 4),
                  base <= buffer.count, view.byteLength <= buffer.count - base,
                  offset <= view.byteLength, (a.count-1)*stride + elementSize <= view.byteLength - offset else { throw StudioAssetError.invalid("accessor bounds") }
            return try buffer.withUnsafeBytes { bytes in
                try (0..<a.count*(vector ? 3 : 1)).map { i in
                    let address = base + offset + (i/(vector ? 3 : 1))*stride + (i%(vector ? 3 : 1))*componentSize
                    let value: Float
                    switch a.componentType {
                    case 5126: value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: address, as: UInt32.self)))
                    case 5121: value = Float(bytes[address])
                    case 5123: value = Float(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: address, as: UInt16.self)))
                    default:
                        let integer = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: address, as: UInt32.self))
                        guard integer < 1_000_000 else { throw StudioAssetError.invalid("index limit") }
                        value = Float(integer)
                    }
                    guard value.isFinite else { throw StudioAssetError.invalid("non-finite geometry") }
                    return value
                }
            }
        }
        var result = StudioScene(name: name, meshes: [])
        var visiting = Set<Int>(), visited = Set<Int>(), vertexTotal = 0, lightCount = 0
        func visit(_ index: Int, parent: simd_float4x4) throws {
            guard !visiting.contains(index), !visited.contains(index), visiting.count < 128 else { throw StudioAssetError.invalid("node hierarchy") }
            visiting.insert(index); visited.insert(index)
            defer { visiting.remove(index) }
            let node = try indexed(doc.nodes, index)
            guard node.skin == nil else { throw StudioAssetError.unsupported("skin") }
            var local = matrix_identity_float4x4
            if let matrix = node.matrix {
                guard matrix.count == 16, node.translation == nil, node.rotation == nil, node.scale == nil else { throw StudioAssetError.invalid("node matrix") }
                local = simd_float4x4(columns: (SIMD4(matrix[0],matrix[1],matrix[2],matrix[3]), SIMD4(matrix[4],matrix[5],matrix[6],matrix[7]), SIMD4(matrix[8],matrix[9],matrix[10],matrix[11]), SIMD4(matrix[12],matrix[13],matrix[14],matrix[15])))
            } else {
                let t = node.translation ?? [0,0,0], r = node.rotation ?? [0,0,0,1], s = node.scale ?? [1,1,1]
                guard t.count == 3, r.count == 4, s.count == 3, simd_length(SIMD4(r[0],r[1],r[2],r[3])) > 0.001 else { throw StudioAssetError.invalid("TRS") }
                local = simd_float4x4(simd_quatf(vector: simd_normalize(SIMD4(r[0],r[1],r[2],r[3]))))
                local.columns.0 *= s[0]; local.columns.1 *= s[1]; local.columns.2 *= s[2]; local.columns.3 = SIMD4(t[0],t[1],t[2],1)
            }
            let world = parent * local
            guard (0..<4).allSatisfy({ world[$0].x.isFinite && world[$0].y.isFinite && world[$0].z.isFinite && world[$0].w.isFinite }), simd_determinant(world) > 0.00001,
                  abs(world.columns.0.w) < 0.0001, abs(world.columns.1.w) < 0.0001,
                  abs(world.columns.2.w) < 0.0001, abs(world.columns.3.w-1) < 0.0001 else { throw StudioAssetError.invalid("singular, reflected or non-affine transform") }
            if let meshIndex = node.mesh {
                for primitive in try indexed(doc.meshes, meshIndex).primitives {
                    guard primitive.mode == nil || primitive.mode == 4, (primitive.targets ?? []).isEmpty,
                          let positionsIndex = primitive.attributes["POSITION"],
                          primitive.attributes.keys.allSatisfy({ ["POSITION","NORMAL"].contains($0) }) else { throw StudioAssetError.unsupported("primitive attributes/mode") }
                    let positions = try values(positionsIndex, vector: true)
                    let normals = try primitive.attributes["NORMAL"].map { try values($0, vector: true) }
                    guard normals == nil || normals?.count == positions.count else { throw StudioAssetError.invalid("normals") }
                    let indices = try primitive.indices.map { try values($0, vector: false).map(Int.init) } ?? Array(0..<positions.count/3)
                    guard indices.count.isMultiple(of: 3), indices.allSatisfy({ $0 >= 0 && $0 < positions.count/3 }) else { throw StudioAssetError.invalid("triangles") }
                    var material = SceneMaterial(baseColor: SIMD4(repeating: 1), metallic: 1, roughness: 1)
                    if let mi = primitive.material {
                        let m = try indexed(doc.materials, mi)
                        guard m.alphaMode == nil || m.alphaMode == "OPAQUE", m.doubleSided != true, m.normalTexture == nil, m.emissiveTexture == nil,
                              m.occlusionTexture == nil, m.extensions == nil, m.pbrMetallicRoughness?.baseColorTexture == nil,
                              m.pbrMetallicRoughness?.metallicRoughnessTexture == nil, (m.emissiveFactor ?? [0,0,0]).allSatisfy({ $0 == 0 }) else { throw StudioAssetError.unsupported("material") }
                        let c = m.pbrMetallicRoughness?.baseColorFactor ?? [1,1,1,1]
                        guard c.count == 4, c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), c[3] == 1 else { throw StudioAssetError.unsupported("baseColor/alpha") }
                        material = .init(baseColor: SIMD4(c[0],c[1],c[2],c[3]), metallic: m.pbrMetallicRoughness?.metallicFactor ?? 1, roughness: m.pbrMetallicRoughness?.roughnessFactor ?? 1)
                        guard (0...1).contains(material.metallic), (0...1).contains(material.roughness) else { throw StudioAssetError.invalid("PBR factors") }
                    }
                    vertexTotal += indices.count
                    guard vertexTotal <= 2_000_000 else { throw StudioAssetError.invalid("scene vertex limit") }
                    let normalTransform = simd_transpose(simd_inverse(simd_float3x3(columns: (world.columns.0.xyz,world.columns.1.xyz,world.columns.2.xyz))))
                    var vertices: [SceneVertex] = []
                    for triangle in stride(from: 0, to: indices.count, by: 3) {
                        let points = (0..<3).map { i -> SIMD4<Float> in let n = indices[triangle+i]*3; return world * SIMD4(positions[n],positions[n+1],positions[n+2],1) }
                        let face = simd_cross(points[1].xyz-points[0].xyz, points[2].xyz-points[0].xyz)
                        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }), simd_length(face).isFinite,
                              simd_length(face) > 0.000001 else { throw StudioAssetError.invalid("degenerate triangle") }
                        for i in 0..<3 {
                            let n = indices[triangle+i]*3
                            let normal = normals.map { normalTransform * SIMD3($0[n],$0[n+1],$0[n+2]) } ?? face
                            guard simd_length(normal).isFinite, simd_length(normal) > 0.000001 else { throw StudioAssetError.invalid("zero normal") }
                            vertices.append(.init(position: points[i], normal: SIMD4(simd_normalize(normal),0)))
                        }
                    }
                    result.meshes.append(.init(vertices: vertices, material: material))
                }
            }
            if let reference = node.extensions?.KHR_lights_punctual {
                lightCount += 1
                let light = try indexed(doc.extensions?.KHR_lights_punctual?.lights, reference.light)
                guard lightCount == 1, light.type == "directional" else { throw StudioAssetError.unsupported("only one directional light") }
                let color = light.color ?? [1,1,1]
                guard color.count == 3, color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), (light.intensity ?? 1).isFinite, (light.intensity ?? 1) >= 0 else { throw StudioAssetError.invalid("light") }
                result.lightColor = SIMD3(color[0],color[1],color[2]); result.lightIntensity = light.intensity ?? 1
                result.lightDirection = simd_normalize(world.columns.2.xyz)
            }
            for child in node.children ?? [] { try visit(child, parent: world) }
        }
        let scene = try indexed(doc.scenes, doc.scene ?? 0)
        for node in scene.nodes ?? [] { try visit(node, parent: matrix_identity_float4x4) }
        guard !result.meshes.isEmpty else { throw StudioAssetError.invalid("empty scene") }
        let positions = result.meshes.flatMap { $0.vertices.map { $0.position.xyz } }
        let lo = positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude),simd_min)
        let hi = positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude),simd_max)
        let center = (lo+hi)/2, radius = max(0.5,simd_length(hi-lo)/2)
        result.cameraWorldTransform = simd_inverse(CameraProjection.lookAt(eye: center+SIMD3(0,radius*0.3,radius*3),target: center))
        return result
    }
}

extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3(x,y,z) } }
