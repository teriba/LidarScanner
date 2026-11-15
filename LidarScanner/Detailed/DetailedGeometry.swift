import Foundation
import simd

// Geometry for detailed rooms. Foundation and simd only, so it also compiles on macOS for testing.

/// An oriented box or flat surface as RoomPlan reports it: the transform puts the
/// origin at the centre, Y is up, `dimensions` is the full size in metres.
struct BoxPose: Codable, Equatable, Sendable {
    /// 4x4 transform, column-major.
    var columns: [Float]
    var size: [Float]

    init(transform: simd_float4x4, dimensions: SIMD3<Float>) {
        let c = transform.columns
        columns = [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        size = [dimensions.x, dimensions.y, dimensions.z]
    }

    var transform: simd_float4x4 {
        guard columns.count == 16 else { return matrix_identity_float4x4 }
        func column(_ i: Int) -> SIMD4<Float> {
            SIMD4(columns[i * 4], columns[i * 4 + 1], columns[i * 4 + 2], columns[i * 4 + 3])
        }
        return simd_float4x4(column(0), column(1), column(2), column(3))
    }

    var dimensions: SIMD3<Float> {
        size.count == 3 ? SIMD3(size[0], size[1], size[2]) : .zero
    }

    var center: SIMD3<Float> { transform.columns.3.xyz }
    /// Rotation about Y, in radians.
    var yaw: Float { atan2(-transform.columns.0.z, transform.columns.0.x) }
    var bottomY: Float { center.y - dimensions.y / 2 }

    /// Largest of |local| / (half size + margin) over the axes. At most 1 inside the grown box.
    func normalizedDistance(_ point: SIMD3<Float>, inverse: simd_float4x4, margin: Float) -> Float {
        let local = simd_abs((inverse * SIMD4<Float>(point, 1)).xyz)
        let half = dimensions / 2 + SIMD3(repeating: margin)
        return simd_reduce_max(local / simd_max(half, SIMD3(repeating: 1e-4)))
    }
}

/// Splits a raw scan mesh between the object boxes of a room.
enum DetailCrop {
    struct Options {
        /// Boxes grow by this much on every side. RoomPlan boxes are often a little tight.
        var margin: Float = 0.05
        /// Triangles closer to the floor than this are floor.
        var floorClearance: Float = 0.03
        /// A wall-class triangle this close to a wall plane is wall. Others can be cabinet
        /// fronts, which ARKit also labels wall.
        var wallTolerance: Float = 0.07
    }

    /// Not in any box, but not room structure either.
    static let loose: Int32 = -1
    /// Floor, ceiling, wall, door or window.
    static let structure: Int32 = -2

    /// Owner per triangle: a box index, `loose` or `structure`.
    /// A triangle inside several boxes goes to the one it sits deepest in.
    static func owners(
        of mesh: TriMesh, boxes: [BoxPose], walls: [BoxPose], floorY: Float?, options: Options = Options()
    ) -> [Int32] {
        let classed = mesh.classes.count == mesh.triangleCount
        let boxInverses = boxes.map { $0.transform.inverse }
        let wallInverses = walls.map { $0.transform.inverse }
        // World bounds of the grown boxes, to skip most triangles quickly.
        let bounds = boxes.map { worldBounds(of: $0, margin: options.margin) }

        func onWall(_ p: SIMD3<Float>) -> Bool {
            for (wall, inverse) in zip(walls, wallInverses) {
                let local = simd_abs((inverse * SIMD4<Float>(p, 1)).xyz)
                let half = wall.dimensions / 2
                if local.z < options.wallTolerance,
                   local.x < half.x + options.wallTolerance,
                   local.y < half.y + options.wallTolerance { return true }
            }
            return false
        }

        var owners = [Int32](repeating: loose, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            let centroid = (a + b + c) / 3
            let faceClass = classed ? MeshClass(rawValue: mesh.classes[t]) ?? .none : .none
            if faceClass == .floor || faceClass == .ceiling || faceClass == .window || faceClass == .door {
                owners[t] = structure
                continue
            }
            if let floorY, centroid.y < floorY + options.floorClearance {
                owners[t] = structure
                continue
            }
            // Unclassified triangles lying on a wall are wall too.
            if faceClass == .wall || faceClass == .none, onWall(centroid) {
                owners[t] = structure
                continue
            }
            var best: Float = 1
            for i in boxes.indices {
                let (low, high) = bounds[i]
                guard centroid.x >= low.x, centroid.x <= high.x,
                      centroid.y >= low.y, centroid.y <= high.y,
                      centroid.z >= low.z, centroid.z <= high.z else { continue }
                let distance = boxes[i].normalizedDistance(centroid, inverse: boxInverses[i], margin: options.margin)
                if distance <= best {
                    best = distance
                    owners[t] = Int32(i)
                }
            }
            if owners[t] == loose, faceClass == .wall { owners[t] = structure }
        }
        return owners
    }

    static func submesh(_ mesh: TriMesh, owners: [Int32], owner: Int32) -> TriMesh {
        MeshProcessing.filtered(mesh, keep: owners.map { $0 == owner })
    }

    /// Weld, drop loose bits, decimate and recompute normals for one cut-out piece.
    /// Nil when fewer than `minTriangles` are left, which is too little to show.
    static func cleaned(_ mesh: TriMesh, maxTriangles: Int, minTriangles: Int = 40) -> TriMesh? {
        guard mesh.triangleCount >= minTriangles else { return nil }
        var result = MeshProcessing.weld(mesh, distance: 0.01)
        result = MeshProcessing.dropSmallComponents(result, minTriangles: 20, minSize: 0.08)
        result = MeshProcessing.decimate(result, targetTriangles: maxTriangles)
        guard result.triangleCount >= minTriangles else { return nil }
        MeshProcessing.recomputeNormals(&result)
        return result
    }

    private static func worldBounds(of box: BoxPose, margin: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        let half = box.dimensions / 2 + SIMD3(repeating: margin)
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = -low
        for corner in 0..<8 {
            let sign = SIMD3<Float>(corner & 1 == 0 ? -1 : 1, corner & 2 == 0 ? -1 : 1, corner & 4 == 0 ? -1 : 1)
            let world = (box.transform * SIMD4<Float>(sign * half, 1)).xyz
            low = simd_min(low, world)
            high = simd_max(high, world)
        }
        return (low, high)
    }
}

/// Per-vertex colours from keyframes.
enum DetailColor {
    /// Linear RGB per vertex. Nil where no keyframe saw the vertex.
    static func vertexColors(of mesh: TriMesh, keyframes: [RoomKeyframe]) -> [SIMD3<Float>?] {
        // No normal test: the depth map already hides what is behind other things.
        mesh.positions.map { KeyframeSampler.color(at: $0, normal: nil, keyframes: keyframes) }
    }

    /// Spreads colours along mesh edges into unseen vertices. What is still unseen
    /// after `passes` rounds gets `fallback`.
    static func filled(
        _ colors: [SIMD3<Float>?], mesh: TriMesh, fallback: SIMD3<Float>, passes: Int = 8
    ) -> [SIMD3<Float>] {
        var current = colors
        for _ in 0..<passes {
            guard current.contains(where: { $0 == nil }) else { break }
            var sums = [SIMD3<Float>](repeating: .zero, count: current.count)
            var counts = [Float](repeating: 0, count: current.count)
            for t in 0..<mesh.triangleCount {
                let corners = (0..<3).map { Int(mesh.indices[t * 3 + $0]) }
                for corner in corners where current[corner] == nil {
                    for other in corners {
                        if let color = current[other] {
                            sums[corner] += color
                            counts[corner] += 1
                        }
                    }
                }
            }
            var changed = false
            for i in current.indices where current[i] == nil && counts[i] > 0 {
                current[i] = sums[i] / counts[i]
                changed = true
            }
            if !changed { break }
        }
        return current.map { $0 ?? fallback }
    }
}

/// A coloured mesh as triangle soup with a palette texture: one texel per triangle,
/// all three corners of a triangle share its texel. Works in SceneKit, USDZ and AR Quick Look,
/// which do not all show vertex colours.
struct PaletteMesh {
    /// Three per triangle.
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// Texture origin at the top left.
    var uvs: [SIMD2<Float>] = []
    var textureWidth = 0
    var textureHeight = 0
    /// RGBA8, sRGB. Empty after `read`, the texture is stored as a PNG next to the mesh.
    var texture: [UInt8] = []

    var triangleCount: Int { positions.count / 3 }

    /// - Parameter colors: linear RGB per vertex of `mesh`.
    init(mesh: TriMesh, colors: [SIMD3<Float>]) {
        let count = mesh.triangleCount
        guard count > 0, colors.count == mesh.positions.count else { return }
        let hasNormals = mesh.normals.count == mesh.positions.count

        // Texels follow a Morton curve through space. Neighbouring texels then have
        // similar colours, so mipmaps and filtering blend into something sensible.
        let (low, high) = mesh.bounds
        let scale = 1023 / max(simd_reduce_max(high - low), 1e-6)
        var order: [(code: UInt32, triangle: Int32)] = []
        order.reserveCapacity(count)
        for t in 0..<count {
            let (a, b, c) = mesh.triangle(t)
            let q = ((a + b + c) / 3 - low) * scale
            order.append((Self.morton(UInt32(q.x), UInt32(q.y), UInt32(q.z)), Int32(t)))
        }
        order.sort { $0.code < $1.code }

        textureWidth = Int(Float(count).squareRoot().rounded(.up))
        textureHeight = (count + textureWidth - 1) / textureWidth
        texture = [UInt8](repeating: 255, count: textureWidth * textureHeight * 4)
        positions.reserveCapacity(count * 3)
        normals.reserveCapacity(count * 3)
        uvs.reserveCapacity(count * 3)

        for (texel, entry) in order.enumerated() {
            let t = Int(entry.triangle)
            let corners = (0..<3).map { Int(mesh.indices[t * 3 + $0]) }
            let (a, b, c) = (mesh.positions[corners[0]], mesh.positions[corners[1]], mesh.positions[corners[2]])
            let cross = simd_cross(b - a, c - a)
            let faceNormal = simd_length_squared(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, 1, 0)
            let color = KeyframeSampler.linearToSRGB((colors[corners[0]] + colors[corners[1]] + colors[corners[2]]) / 3)
            let (column, row) = (texel % textureWidth, texel / textureWidth)
            for channel in 0..<3 {
                texture[texel * 4 + channel] = UInt8((color[channel] * 255).rounded())
            }
            let uv = SIMD2((Float(column) + 0.5) / Float(textureWidth), (Float(row) + 0.5) / Float(textureHeight))
            for corner in corners {
                positions.append(mesh.positions[corner])
                normals.append(hasNormals ? mesh.normals[corner] : faceNormal)
                uvs.append(uv)
            }
        }
        // Unused texels at the end repeat the last colour, so they do not bleed white.
        if count < textureWidth * textureHeight {
            let last = (count - 1) * 4
            for texel in count..<(textureWidth * textureHeight) {
                for channel in 0..<3 { texture[texel * 4 + channel] = texture[last + channel] }
            }
        }
    }

    /// Interleaves the low 10 bits of x, y and z.
    static func morton(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        func spread(_ value: UInt32) -> UInt32 {
            var v = value & 0x3FF
            v = (v | (v << 16)) & 0x030000FF
            v = (v | (v << 8)) & 0x0300F00F
            v = (v | (v << 4)) & 0x030C30C3
            v = (v | (v << 2)) & 0x09249249
            return v
        }
        return spread(x) | (spread(y) << 1) | (spread(z) << 2)
    }

    // MARK: File

    private static let magic: UInt32 = 0x4D50_534C // "LSPM"

    /// Geometry only: magic, vertex count, then positions, normals and uvs as Float32.
    func write(to url: URL) throws {
        var data = Data(capacity: 8 + positions.count * 32)
        func append<T>(_ values: [T]) { values.withUnsafeBytes { data.append(contentsOf: $0) } }
        append([Self.magic, UInt32(positions.count)])
        append(positions.flatMap { [$0.x, $0.y, $0.z] })
        append(normals.flatMap { [$0.x, $0.y, $0.z] })
        append(uvs.flatMap { [$0.x, $0.y] })
        try data.write(to: url, options: .atomic)
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 8 else { throw CocoaError(.fileReadCorruptFile) }
        let header = data.prefix(8).withUnsafeBytes { ($0.loadUnaligned(as: UInt32.self), $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let count = Int(header.1)
        guard header.0 == Self.magic, data.count == 8 + count * 32 else { throw CocoaError(.fileReadCorruptFile) }
        let floats: [Float] = data.dropFirst(8).withUnsafeBytes { raw in
            (0..<(count * 8)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        positions = (0..<count).map { SIMD3(floats[$0 * 3], floats[$0 * 3 + 1], floats[$0 * 3 + 2]) }
        normals = (0..<count).map { SIMD3(floats[(count + $0) * 3], floats[(count + $0) * 3 + 1], floats[(count + $0) * 3 + 2]) }
        uvs = (0..<count).map { SIMD2(floats[count * 6 + $0 * 2], floats[count * 6 + $0 * 2 + 1]) }
    }
}

/// Where a replacement model goes when it stands in for a box.
enum ObjectPlacement {
    /// Uniform scale that makes a model of `modelSize` just fit inside the box.
    /// An odd number of quarter turns swaps the model's width and depth.
    static func fitScale(box: SIMD3<Float>, modelSize: SIMD3<Float>, quarterTurns: Int) -> Float {
        let turned = quarterTurns % 2 == 0 ? modelSize : SIMD3(modelSize.z, modelSize.y, modelSize.x)
        let ratios = box / simd_max(turned, SIMD3(repeating: 1e-4))
        let scale = simd_reduce_min(ratios)
        return scale.isFinite && scale > 0 ? scale : 1
    }

    /// World transform for a model with the given local bounds: centred on the box
    /// footprint, standing on the box's bottom face, turned to the box yaw plus quarter
    /// turns. `nudge` is in metres along the box axes.
    static func transform(
        box: BoxPose,
        modelMin: SIMD3<Float>,
        modelMax: SIMD3<Float>,
        fitToBox: Bool,
        quarterTurns: Int,
        nudge: SIMD3<Float>
    ) -> simd_float4x4 {
        let scale = fitToBox
            ? fitScale(box: box.dimensions, modelSize: modelMax - modelMin, quarterTurns: quarterTurns)
            : 1
        let modelCentre = (modelMin + modelMax) / 2
        let toOrigin = translation(SIMD3(-modelCentre.x, -modelMin.y, -modelCentre.z))
        let scaling = simd_float4x4(diagonal: SIMD4(scale, scale, scale, 1))
        let turn = rotationY(Float(quarterTurns) * .pi / 2)
        let boxFrame = translation(SIMD3(box.center.x, box.bottomY, box.center.z)) * rotationY(box.yaw)
        return boxFrame * translation(nudge) * turn * scaling * toOrigin
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(t, 1)
        return matrix
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let (s, c) = (sin(angle), cos(angle))
        return simd_float4x4(
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }
}
