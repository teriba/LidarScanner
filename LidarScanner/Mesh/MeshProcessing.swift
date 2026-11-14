import Foundation
import simd

/// Surface class per triangle. Raw values 0...7 match ARMeshClassification.
enum MeshClass: UInt8, CaseIterable {
    case none, wall, floor, ceiling, table, seat, window, door
    /// Not an ARKit class. Used for furniture in converted rooms.
    case furniture

    /// OBJ group name.
    var name: String {
        switch self {
        case .none: "unclassified"
        case .wall: "wall"
        case .floor: "floor"
        case .ceiling: "ceiling"
        case .table: "table"
        case .seat: "seat"
        case .window: "window"
        case .door: "door"
        case .furniture: "furniture"
        }
    }

    init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }
}

/// Indexed triangle mesh in metres, Y up.
struct TriMesh {
    var positions: [SIMD3<Float>] = []
    /// Empty, or one per vertex.
    var normals: [SIMD3<Float>] = []
    /// Three per triangle.
    var indices: [UInt32] = []
    /// Empty, or one MeshClass raw value per triangle.
    var classes: [UInt8] = []

    var triangleCount: Int { indices.count / 3 }

    /// True when at least one triangle has a class other than none.
    var hasClasses: Bool {
        classes.count == triangleCount && classes.contains { $0 != 0 }
    }

    func triangle(_ index: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        (positions[Int(indices[index * 3])], positions[Int(indices[index * 3 + 1])], positions[Int(indices[index * 3 + 2])])
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }
}

/// Clean up and simplification for raw scan meshes. No UI or ARKit dependencies.
enum MeshProcessing {
    struct CleanOptions {
        /// Vertices closer than this are merged.
        var weldDistance: Float = 0.01
        /// Disconnected pieces with fewer triangles are dropped.
        var minComponentTriangles = 30
        /// Disconnected pieces with a smaller bounding box diagonal are dropped.
        var minComponentSize: Float = 0.25
        /// Share of triangles to keep when decimating.
        var targetRatio: Float = 0.35
        /// Upper limit on triangles after decimation.
        var maxTriangles = 250_000
    }

    /// Weld, remove bad triangles, drop small pieces, decimate, recompute normals.
    static func cleaned(
        _ mesh: TriMesh,
        options: CleanOptions = CleanOptions(),
        progress: (Double) -> Void = { _ in }
    ) -> TriMesh {
        var result = weld(mesh, distance: options.weldDistance)
        progress(0.4)
        result = dropSmallComponents(
            result,
            minTriangles: options.minComponentTriangles,
            minSize: options.minComponentSize
        )
        progress(0.6)
        let target = min(options.maxTriangles, Int(Float(result.triangleCount) * options.targetRatio))
        result = decimate(result, targetTriangles: target)
        progress(0.9)
        recomputeNormals(&result)
        progress(1)
        return result
    }

    // MARK: Weld

    /// Merges vertices within `distance` of each other and removes the triangles that
    /// collapse or repeat as a result. The first vertex seen keeps its position.
    static func weld(_ mesh: TriMesh, distance: Float) -> TriMesh {
        let count = mesh.positions.count
        let tolerance = max(distance, 1e-6)
        let inverseCell = 1 / (tolerance * 2)
        let limit = tolerance * tolerance

        var heads: [UInt64: Int32] = [:]
        heads.reserveCapacity(count / 2)
        var next: [Int32] = []
        var kept: [SIMD3<Float>] = []
        var remap = [UInt32](repeating: .max, count: count)

        for i in 0..<count {
            let p = mesh.positions[i]
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, simd_reduce_max(simd_abs(p)) < 1e5 else { continue }
            // Cells are twice the tolerance, so a match is in one of at most 8 cells.
            let lo = cellCoordinate((p - tolerance) * inverseCell)
            let hi = cellCoordinate((p + tolerance) * inverseCell)
            var found: Int32 = -1
            search: for x in lo.x...hi.x {
                for y in lo.y...hi.y {
                    for z in lo.z...hi.z {
                        var candidate = heads[cellKey(SIMD3(x, y, z))] ?? -1
                        while candidate >= 0 {
                            if simd_distance_squared(kept[Int(candidate)], p) <= limit {
                                found = candidate
                                break search
                            }
                            candidate = next[Int(candidate)]
                        }
                    }
                }
            }
            if found < 0 {
                found = Int32(kept.count)
                kept.append(p)
                let key = cellKey(cellCoordinate(p * inverseCell))
                next.append(heads[key] ?? -1)
                heads[key] = found
            }
            remap[i] = UInt32(found)
        }
        return rebuilt(mesh, positions: kept, remap: remap)
    }

    private static func cellCoordinate(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32(p.x.rounded(.down)), Int32(p.y.rounded(.down)), Int32(p.z.rounded(.down)))
    }

    private static func cellKey(_ c: SIMD3<Int32>) -> UInt64 {
        let mask: UInt64 = 0x1F_FFFF
        return (UInt64(truncatingIfNeeded: c.x) & mask)
            | (UInt64(truncatingIfNeeded: c.y) & mask) << 21
            | (UInt64(truncatingIfNeeded: c.z) & mask) << 42
    }

    private struct TriangleKey: Hashable {
        let a, b, c: UInt32

        init(_ i: UInt32, _ j: UInt32, _ k: UInt32) {
            a = min(i, j, k)
            c = max(i, j, k)
            b = i ^ j ^ k ^ a ^ c
        }
    }

    /// Applies a vertex remap, then drops degenerate and duplicate triangles and unused vertices.
    private static func rebuilt(_ mesh: TriMesh, positions: [SIMD3<Float>], remap: [UInt32]) -> TriMesh {
        let keepClasses = mesh.classes.count == mesh.triangleCount
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        var classes: [UInt8] = []
        var seen = Set<TriangleKey>()
        seen.reserveCapacity(mesh.triangleCount)
        var used = [Bool](repeating: false, count: positions.count)

        for t in 0..<mesh.triangleCount {
            let a = remap[Int(mesh.indices[t * 3])]
            let b = remap[Int(mesh.indices[t * 3 + 1])]
            let c = remap[Int(mesh.indices[t * 3 + 2])]
            guard a != .max, b != .max, c != .max, a != b, b != c, a != c else { continue }
            let pa = positions[Int(a)]
            let area = simd_length_squared(simd_cross(positions[Int(b)] - pa, positions[Int(c)] - pa))
            guard area > 1e-14 else { continue }
            guard seen.insert(TriangleKey(a, b, c)).inserted else { continue }
            indices.append(contentsOf: [a, b, c])
            if keepClasses { classes.append(mesh.classes[t]) }
            used[Int(a)] = true
            used[Int(b)] = true
            used[Int(c)] = true
        }

        var compact = [UInt32](repeating: 0, count: positions.count)
        var result = TriMesh()
        result.positions.reserveCapacity(positions.count)
        for i in 0..<positions.count where used[i] {
            compact[i] = UInt32(result.positions.count)
            result.positions.append(positions[i])
        }
        for i in indices.indices { indices[i] = compact[Int(indices[i])] }
        result.indices = indices
        result.classes = classes
        return result
    }

    // MARK: Components

    /// Labels each triangle with the index of its connected component (shared vertices).
    static func componentLabels(_ mesh: TriMesh, include: [Bool]? = nil) -> (labels: [Int32], count: Int) {
        var parent = [Int32](0..<Int32(mesh.positions.count))
        func find(_ start: Int32) -> Int32 {
            var root = start
            while parent[Int(root)] != root { root = parent[Int(root)] }
            var node = start
            while parent[Int(node)] != root {
                let up = parent[Int(node)]
                parent[Int(node)] = root
                node = up
            }
            return root
        }
        for t in 0..<mesh.triangleCount where include?[t] ?? true {
            let a = find(Int32(mesh.indices[t * 3]))
            let b = find(Int32(mesh.indices[t * 3 + 1]))
            let c = find(Int32(mesh.indices[t * 3 + 2]))
            parent[Int(b)] = a
            parent[Int(c)] = a
        }
        var labelOfRoot = [Int32](repeating: -1, count: mesh.positions.count)
        var labels = [Int32](repeating: -1, count: mesh.triangleCount)
        var count: Int32 = 0
        for t in 0..<mesh.triangleCount where include?[t] ?? true {
            let root = Int(find(Int32(mesh.indices[t * 3])))
            if labelOfRoot[root] < 0 {
                labelOfRoot[root] = count
                count += 1
            }
            labels[t] = labelOfRoot[root]
        }
        return (labels, Int(count))
    }

    struct Component {
        var triangles = 0
        var area: Float = 0
        var min = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var max = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        var size: Float { simd_length(max - min) }
    }

    static func componentStats(_ mesh: TriMesh, labels: [Int32], count: Int) -> [Component] {
        var stats = [Component](repeating: Component(), count: count)
        for t in 0..<mesh.triangleCount where labels[t] >= 0 {
            let (a, b, c) = mesh.triangle(t)
            let label = Int(labels[t])
            stats[label].triangles += 1
            stats[label].area += simd_length(simd_cross(b - a, c - a)) / 2
            stats[label].min = simd_min(stats[label].min, simd_min(a, simd_min(b, c)))
            stats[label].max = simd_max(stats[label].max, simd_max(a, simd_max(b, c)))
        }
        return stats
    }

    /// Drops disconnected pieces that are small by triangle count or bounding size.
    /// The largest piece always stays.
    static func dropSmallComponents(_ mesh: TriMesh, minTriangles: Int, minSize: Float) -> TriMesh {
        let (labels, count) = componentLabels(mesh)
        guard count > 1 else { return mesh }
        let stats = componentStats(mesh, labels: labels, count: count)
        let largest = stats.indices.max { stats[$0].triangles < stats[$1].triangles }
        let keepComponent = stats.indices.map {
            $0 == largest || (stats[$0].triangles >= minTriangles && stats[$0].size >= minSize)
        }
        return filtered(mesh, keep: labels.map { keepComponent[Int($0)] })
    }

    /// Keeps the triangles flagged in `keep` and drops vertices that become unused.
    static func filtered(_ mesh: TriMesh, keep: [Bool]) -> TriMesh {
        let keepClasses = mesh.classes.count == mesh.triangleCount
        let keepNormals = mesh.normals.count == mesh.positions.count
        var compact = [UInt32](repeating: .max, count: mesh.positions.count)
        var result = TriMesh()
        for t in 0..<mesh.triangleCount where keep[t] {
            for corner in 0..<3 {
                let source = Int(mesh.indices[t * 3 + corner])
                if compact[source] == .max {
                    compact[source] = UInt32(result.positions.count)
                    result.positions.append(mesh.positions[source])
                    if keepNormals { result.normals.append(mesh.normals[source]) }
                }
                result.indices.append(compact[source])
            }
            if keepClasses { result.classes.append(mesh.classes[t]) }
        }
        return result
    }

    // MARK: Decimation

    static func surfaceArea(_ mesh: TriMesh) -> Float {
        var area: Float = 0
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            area += simd_length(simd_cross(b - a, c - a)) / 2
        }
        return area
    }

    /// Vertex clustering: every vertex in a grid cell moves to the cell's mean position.
    /// One linear pass, no topology requirements, so it copes with noisy scan meshes.
    static func clustered(_ mesh: TriMesh, cell: Float) -> TriMesh {
        let origin = mesh.bounds.min
        let inverseCell = 1 / cell
        var clusterOfCell: [UInt64: UInt32] = [:]
        clusterOfCell.reserveCapacity(mesh.positions.count / 4)
        var sums: [SIMD3<Float>] = []
        var counts: [Float] = []
        var remap = [UInt32](repeating: 0, count: mesh.positions.count)
        for i in 0..<mesh.positions.count {
            let p = mesh.positions[i]
            let key = cellKey(cellCoordinate((p - origin) * inverseCell))
            if let cluster = clusterOfCell[key] {
                sums[Int(cluster)] += p
                counts[Int(cluster)] += 1
                remap[i] = cluster
            } else {
                let cluster = UInt32(sums.count)
                clusterOfCell[key] = cluster
                sums.append(p)
                counts.append(1)
                remap[i] = cluster
            }
        }
        for i in sums.indices { sums[i] /= counts[i] }
        return rebuilt(mesh, positions: sums, remap: remap)
    }

    /// Decimates to roughly `targetTriangles` by searching for a cluster cell size.
    /// Returns the mesh unchanged when it is already small enough.
    static func decimate(_ mesh: TriMesh, targetTriangles: Int) -> TriMesh {
        let target = max(targetTriangles, 4)
        guard mesh.triangleCount > target else { return mesh }
        // A flat surface clustered at cell size c keeps about 2 triangles per c².
        var cell = (2 * surfaceArea(mesh) / Float(target)).squareRoot()
        guard cell.isFinite, cell > 0 else { return mesh }
        var best: TriMesh?
        for _ in 0..<6 {
            let candidate = clustered(mesh, cell: cell)
            let count = candidate.triangleCount
            if count <= target, count > (best?.triangleCount ?? 0) { best = candidate }
            if count <= target, Float(count) >= Float(target) * 0.85 { break }
            // Aim slightly under the target so the search ends on the low side.
            let ratio = Float(max(count, 1)) / (Float(target) * 0.93)
            cell *= min(max(ratio.squareRoot(), 0.5), 2)
        }
        return best ?? clustered(mesh, cell: cell * 1.5)
    }

    // MARK: Normals

    /// Smooth vertex normals, weighted by triangle area.
    static func recomputeNormals(_ mesh: inout TriMesh) {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            let weighted = simd_cross(b - a, c - a)
            normals[Int(mesh.indices[t * 3])] += weighted
            normals[Int(mesh.indices[t * 3 + 1])] += weighted
            normals[Int(mesh.indices[t * 3 + 2])] += weighted
        }
        for i in normals.indices {
            let length = simd_length(normals[i])
            normals[i] = length > 1e-12 ? normals[i] / length : SIMD3(0, 1, 0)
        }
        mesh.normals = normals
    }

    // MARK: Holes

    /// Closes boundary loops up to `maxPerimeter` metres with a triangle fan around
    /// the loop centre. Returns the number of holes filled.
    @discardableResult
    static func fillSmallHoles(_ mesh: inout TriMesh, maxPerimeter: Float, maxEdges: Int = 64) -> Int {
        var edges = Set<UInt64>()
        edges.reserveCapacity(mesh.indices.count)
        for t in 0..<mesh.triangleCount {
            for corner in 0..<3 {
                let from = UInt64(mesh.indices[t * 3 + corner])
                let to = UInt64(mesh.indices[t * 3 + (corner + 1) % 3])
                edges.insert(from << 32 | to)
            }
        }
        // A boundary edge has no opposite twin. Vertices where several boundaries
        // meet are ambiguous and their loops are left open.
        var nextOnBoundary: [UInt32: UInt32] = [:]
        var ambiguous = Set<UInt32>()
        for edge in edges where !edges.contains(edge << 32 | edge >> 32) {
            let from = UInt32(edge >> 32)
            let to = UInt32(truncatingIfNeeded: edge)
            if nextOnBoundary.updateValue(to, forKey: from) != nil { ambiguous.insert(from) }
        }

        let keepClasses = mesh.classes.count == mesh.triangleCount
        var visited = Set<UInt32>()
        var filled = 0
        for start in nextOnBoundary.keys.sorted() where !visited.contains(start) {
            var loop: [UInt32] = []
            var perimeter: Float = 0
            var current = start
            var closed = false
            while loop.count <= maxEdges, !ambiguous.contains(current), visited.insert(current).inserted {
                loop.append(current)
                guard let following = nextOnBoundary[current] else { break }
                perimeter += simd_distance(mesh.positions[Int(current)], mesh.positions[Int(following)])
                if following == start {
                    closed = true
                    break
                }
                current = following
            }
            guard closed, loop.count >= 3, loop.count <= maxEdges, perimeter <= maxPerimeter else { continue }

            if loop.count == 3 {
                mesh.indices.append(contentsOf: [loop[1], loop[0], loop[2]])
                if keepClasses { mesh.classes.append(0) }
            } else {
                let centre = loop.reduce(SIMD3<Float>.zero) { $0 + mesh.positions[Int($1)] } / Float(loop.count)
                let centreIndex = UInt32(mesh.positions.count)
                mesh.positions.append(centre)
                if !mesh.normals.isEmpty { mesh.normals.append(SIMD3(0, 1, 0)) }
                for i in loop.indices {
                    // Reverse of the boundary direction, so the fan faces the same way as its neighbours.
                    mesh.indices.append(contentsOf: [loop[(i + 1) % loop.count], loop[i], centreIndex])
                    if keepClasses { mesh.classes.append(0) }
                }
            }
            filled += 1
        }
        return filled
    }
}
