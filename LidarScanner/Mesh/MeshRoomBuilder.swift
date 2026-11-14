import Foundation
import simd

enum MeshRoomError: LocalizedError {
    case noFloor

    var errorDescription: String? {
        "No floor found in this mesh. Scan more of the floor and try again."
    }
}

/// Turns a cleaned scan mesh into flat room geometry: floor, ceiling, wall quads and furniture.
/// Uses ARKit face classes when the mesh has them, and geometry alone otherwise.
enum MeshRoomBuilder {
    enum Furniture {
        case none
        /// One box per furniture-sized cluster, aligned with the main wall.
        case boxes
        /// The cluster's own triangles.
        case meshes
    }

    struct Options {
        var furniture: Furniture = .boxes
        var minWallArea: Float = 0.6
        var maxFurniture = 64
    }

    struct Room {
        var mesh = TriMesh()
        var floorHeight: Float = 0
        var ceilingHeight: Float?
        var wallCount = 0
        var furnitureCount = 0
        /// True when the walls closed into a loop and the floor is that polygon.
        /// False when the floor is built from the scanned floor area instead.
        var floorFollowsWalls = false
    }

    /// A stretch of a wall plane, `start` to `end` along the wall tangent.
    private struct Segment {
        var wall: Int
        var start: Float
        var end: Float
        var top: Float
    }

    static func build(from mesh: TriMesh, options: Options = Options()) throws -> Room {
        let faces = MeshPlanes.Faces(mesh)
        let faceCount = mesh.triangleCount
        let classed = mesh.hasClasses
        func faceClass(_ t: Int) -> MeshClass { classed ? MeshClass(rawValue: mesh.classes[t]) ?? .none : .none }

        // Floor: the lowest large upward-facing level.
        var floorSelect: (Int) -> Bool = { faces.isUpward($0) }
        if classed {
            var classedArea: Float = 0
            for t in 0..<faceCount where faces.isUpward(t) && faceClass(t) == .floor { classedArea += faces.areas[t] }
            if classedArea >= 0.5 { floorSelect = { faces.isUpward($0) && faceClass($0) == .floor } }
        }
        let floorLevels = MeshPlanes.levels(faces, select: floorSelect)
        let largestFloor = floorLevels.map(\.area).max() ?? 0
        guard let floor = floorLevels.first(where: { $0.area >= max(0.3, 0.2 * largestFloor) }) else {
            throw MeshRoomError.noFloor
        }
        let floorY = floor.height

        // Ceiling: the highest large downward-facing level. Optional.
        let ceilingLevels = MeshPlanes.levels(faces) { faces.isDownward($0) && faces.centroids[$0].y > floorY + 1.5 }
        let largestCeiling = ceilingLevels.map(\.area).max() ?? 0
        let ceilingY = ceilingLevels.last { $0.area >= max(0.3, 0.2 * largestCeiling) }?.height
        let top = ceilingY ?? mesh.bounds.max.y

        let isFloor = (0..<faceCount).map { faces.isUpward($0) && abs(faces.centroids[$0].y - floorY) <= 0.06 }
        let isCeiling = (0..<faceCount).map { t in
            ceilingY.map { faces.isDownward(t) && abs(faces.centroids[t].y - $0) <= 0.08 } ?? false
        }

        // Walls.
        var wallOptions = MeshPlanes.WallOptions()
        wallOptions.minArea = options.minWallArea
        wallOptions.minHeight = min(1.0, 0.5 * (top - floorY))
        let detected = MeshPlanes.walls(mesh, faces: faces, select: { t in
            guard !isFloor[t], !isCeiling[t] else { return false }
            let y = faces.centroids[t].y
            guard y > floorY - 0.05, y < top + 0.05 else { return false }
            let kind = faceClass(t)
            return kind != .floor && kind != .ceiling && kind != .table && kind != .seat
        }, options: wallOptions)
        var walls = detected.walls
        let wallOfFace = detected.wallOfFace
        snapToRightAngles(&walls, wallOfFace: wallOfFace, faces: faces)

        var segments = wallSegments(
            mesh, walls: walls, wallOfFace: wallOfFace, ceiling: ceilingY, minHeight: wallOptions.minHeight
        )
        closeCorners(&segments, walls: walls)
        func point(_ segment: Segment, _ along: Float) -> SIMD2<Float> {
            walls[segment.wall].normal * walls[segment.wall].offset + walls[segment.wall].tangent * along
        }

        // Room axes follow the largest wall, so boxes and floor tiles line up with it.
        let axisU = walls.first?.tangent ?? SIMD2(1, 0)
        let axisV = walls.first?.normal ?? SIMD2(0, 1)

        var room = Room(floorHeight: floorY, ceilingHeight: ceilingY, wallCount: segments.count)
        var builder = Builder()

        // Floor and ceiling outline: the wall loop when it closes around the scanned
        // floor, otherwise rectangles covering the scanned floor area.
        var outline: [SIMD2<Float>]?
        if let loop = largestLoop(segments, point: point), let triangles = triangulate(loop) {
            var inside: Float = 0
            var total: Float = 0
            for t in 0..<faceCount where isFloor[t] {
                total += faces.areas[t]
                if contains(loop, SIMD2(faces.centroids[t].x, faces.centroids[t].z)) { inside += faces.areas[t] }
            }
            if total > 0, inside / total >= 0.85 {
                outline = loop
                room.floorFollowsWalls = true
                for (a, b, c) in triangles {
                    let corners = [loop[a], loop[b], loop[c]]
                    builder.addTriangle(corners.map { SIMD3($0.x, floorY, $0.y) }, facing: SIMD3(0, 1, 0), kind: .floor)
                    if let ceilingY {
                        builder.addTriangle(
                            corners.map { SIMD3($0.x, ceilingY, $0.y) }, facing: SIMD3(0, -1, 0), kind: .ceiling
                        )
                    }
                }
            }
        }
        if outline == nil {
            let tiles = floorTiles(mesh, isFloor: isFloor, faces: faces, axisU: axisU, axisV: axisV)
            for tile in tiles {
                let corners = [
                    SIMD2(tile.minU, tile.minV), SIMD2(tile.maxU, tile.minV),
                    SIMD2(tile.maxU, tile.maxV), SIMD2(tile.minU, tile.maxV),
                ].map { axisU * $0.x + axisV * $0.y }
                builder.addQuad(corners.map { SIMD3($0.x, floorY, $0.y) }, facing: SIMD3(0, 1, 0), kind: .floor)
                if let ceilingY {
                    builder.addQuad(corners.map { SIMD3($0.x, ceilingY, $0.y) }, facing: SIMD3(0, -1, 0), kind: .ceiling)
                }
            }
        }

        for segment in segments {
            let from = point(segment, segment.start)
            let to = point(segment, segment.end)
            let normal = walls[segment.wall].normal
            builder.addQuad([
                SIMD3(from.x, floorY, from.y), SIMD3(to.x, floorY, to.y),
                SIMD3(to.x, segment.top, to.y), SIMD3(from.x, segment.top, from.y),
            ], facing: SIMD3(normal.x, 0, normal.y), kind: .wall)
        }

        // Furniture: what is left between floor and ceiling, away from the walls.
        if options.furniture != .none {
            let candidate = (0..<faceCount).map { t -> Bool in
                guard !isFloor[t], !isCeiling[t], wallOfFace[t] < 0 else { return false }
                let p = faces.centroids[t]
                guard p.y > floorY + 0.08, p.y < top - 0.08 else { return false }
                switch faceClass(t) {
                case .wall, .floor, .ceiling, .window, .door: return false
                default: break
                }
                if let outline, !contains(outline, SIMD2(p.x, p.z)) { return false }
                for segment in segments {
                    let wall = walls[segment.wall]
                    let along = simd_dot(wall.tangent, SIMD2(p.x, p.z))
                    if abs(wall.distance(p)) <= 0.12, along >= segment.start - 0.1, along <= segment.end + 0.1 {
                        return false
                    }
                }
                return true
            }
            let (labels, count) = MeshProcessing.componentLabels(mesh, include: candidate)
            let stats = MeshProcessing.componentStats(mesh, labels: labels, count: count)
            let kept = stats.indices
                .filter { stats[$0].triangles >= 12 && stats[$0].size >= 0.3 && stats[$0].area >= 0.15 }
                .sorted { stats[$0].area > stats[$1].area }
                .prefix(options.maxFurniture)
            room.furnitureCount = kept.count

            var slotOfLabel = [Int](repeating: -1, count: count)
            for (slot, label) in kept.enumerated() { slotOfLabel[label] = slot }
            var low = [SIMD3<Float>](repeating: SIMD3(repeating: .greatestFiniteMagnitude), count: kept.count)
            var high = [SIMD3<Float>](repeating: SIMD3(repeating: -.greatestFiniteMagnitude), count: kept.count)
            for t in 0..<faceCount where labels[t] >= 0 && slotOfLabel[Int(labels[t])] >= 0 {
                let slot = slotOfLabel[Int(labels[t])]
                let (a, b, c) = mesh.triangle(t)
                if options.furniture == .meshes {
                    builder.addTriangle([a, b, c], facing: nil, kind: .furniture)
                } else {
                    for p in [a, b, c] {
                        // Box extents in room axes: (along main wall, up, away from main wall).
                        let local = SIMD3(simd_dot(axisU, SIMD2(p.x, p.z)), p.y, simd_dot(axisV, SIMD2(p.x, p.z)))
                        low[slot] = simd_min(low[slot], local)
                        high[slot] = simd_max(high[slot], local)
                    }
                }
            }
            if options.furniture == .boxes {
                for slot in 0..<kept.count {
                    // Furniture standing on the floor rarely scans all the way down.
                    if low[slot].y - floorY < 0.2 { low[slot].y = floorY }
                    builder.addBox(low: low[slot], high: high[slot], axisU: axisU, axisV: axisV, kind: .furniture)
                }
            }
        }

        room.mesh = builder.mesh
        return room
    }

    // MARK: Walls

    /// Turns walls that are nearly parallel or perpendicular to the largest wall exactly so,
    /// then refits every offset to its faces.
    private static func snapToRightAngles(_ walls: inout [MeshPlanes.Wall], wallOfFace: [Int32], faces: MeshPlanes.Faces) {
        guard let main = walls.first else { return }
        let base = atan2(main.normal.y, main.normal.x)
        for i in walls.indices.dropFirst() {
            let angle = atan2(walls[i].normal.y, walls[i].normal.x)
            let snapped = base + ((angle - base) / (.pi / 2)).rounded() * (.pi / 2)
            if abs(angle - snapped) < 7 * .pi / 180 {
                walls[i].normal = SIMD2(cos(snapped), sin(snapped))
            }
        }
        var sum = [Float](repeating: 0, count: walls.count)
        var weight = [Float](repeating: 0, count: walls.count)
        for t in wallOfFace.indices where wallOfFace[t] >= 0 {
            let wall = Int(wallOfFace[t])
            let p = SIMD2(faces.centroids[t].x, faces.centroids[t].z)
            sum[wall] += faces.areas[t] * simd_dot(walls[wall].normal, p)
            weight[wall] += faces.areas[t]
        }
        for i in walls.indices where weight[i] > 0 { walls[i].offset = sum[i] / weight[i] }
    }

    /// Splits each wall plane into the stretches the scan covers. Gaps up to 0.5 m are bridged.
    private static func wallSegments(
        _ mesh: TriMesh,
        walls: [MeshPlanes.Wall],
        wallOfFace: [Int32],
        ceiling: Float?,
        minHeight: Float
    ) -> [Segment] {
        var facesOfWall = [[Int32]](repeating: [], count: walls.count)
        for t in wallOfFace.indices where wallOfFace[t] >= 0 { facesOfWall[Int(wallOfFace[t])].append(Int32(t)) }

        let step: Float = 0.1
        let maxGap = 5
        var segments: [Segment] = []
        for (index, wall) in walls.enumerated() {
            let tangent = wall.tangent
            func span(_ t: Int32) -> (low: Float, high: Float, minY: Float, maxY: Float) {
                let (a, b, c) = mesh.triangle(Int(t))
                let along = [a, b, c].map { simd_dot(tangent, SIMD2($0.x, $0.z)) }
                return (along.min()!, along.max()!, min(a.y, b.y, c.y), max(a.y, b.y, c.y))
            }
            var low = Float.greatestFiniteMagnitude
            var high = -Float.greatestFiniteMagnitude
            for t in facesOfWall[index] {
                let s = span(t)
                low = min(low, s.low)
                high = max(high, s.high)
            }
            guard high > low else { continue }
            let count = Int((high - low) / step) + 1
            var covered = [Bool](repeating: false, count: count)
            var minY = [Float](repeating: .greatestFiniteMagnitude, count: count)
            var maxY = [Float](repeating: -.greatestFiniteMagnitude, count: count)
            for t in facesOfWall[index] {
                let s = span(t)
                for bin in Int((s.low - low) / step)...min(Int((s.high - low) / step), count - 1) {
                    covered[bin] = true
                    minY[bin] = min(minY[bin], s.minY)
                    maxY[bin] = max(maxY[bin], s.maxY)
                }
            }

            var bin = 0
            while bin < count {
                guard covered[bin] else {
                    bin += 1
                    continue
                }
                var last = bin
                var runMinY = minY[bin]
                var runMaxY = maxY[bin]
                var probe = bin + 1
                while probe < count, probe - last <= maxGap + 1 {
                    if covered[probe] {
                        last = probe
                        runMinY = min(runMinY, minY[probe])
                        runMaxY = max(runMaxY, maxY[probe])
                    }
                    probe += 1
                }
                let start = low + Float(bin) * step
                let end = min(low + Float(last + 1) * step, high)
                if end - start >= 0.4, runMaxY - runMinY >= minHeight {
                    segments.append(Segment(wall: index, start: start, end: end, top: ceiling ?? runMaxY))
                }
                bin = last + 1
            }
        }
        return segments
    }

    /// Moves segment ends onto the crossing with a nearby wall, so corners meet exactly.
    private static func closeCorners(_ segments: inout [Segment], walls: [MeshPlanes.Wall]) {
        let reach: Float = 0.5
        let original = segments
        for i in original.indices {
            let wall = walls[original[i].wall]
            for isEnd in [false, true] {
                let current = isEnd ? original[i].end : original[i].start
                var bestDelta = reach
                var best: Float?
                for j in original.indices where original[j].wall != original[i].wall {
                    let other = walls[original[j].wall]
                    let denominator = simd_dot(wall.tangent, other.normal)
                    guard abs(denominator) > 0.3 else { continue }
                    let along = (other.offset - wall.offset * simd_dot(wall.normal, other.normal)) / denominator
                    let crossing = wall.normal * wall.offset + wall.tangent * along
                    let alongOther = simd_dot(other.tangent, crossing)
                    guard alongOther >= original[j].start - reach, alongOther <= original[j].end + reach else { continue }
                    if abs(along - current) < bestDelta {
                        bestDelta = abs(along - current)
                        best = along
                    }
                }
                guard let best else { continue }
                if isEnd, best > segments[i].start + 0.1 { segments[i].end = best }
                if !isEnd, best < segments[i].end - 0.1 { segments[i].start = best }
            }
        }
    }

    // MARK: Floor outline

    /// Chains segments that share corners into closed loops and returns the largest one.
    private static func largestLoop(_ segments: [Segment], point: (Segment, Float) -> SIMD2<Float>) -> [SIMD2<Float>]? {
        guard segments.count >= 3 else { return nil }
        let ends = segments.map { (start: point($0, $0.start), end: point($0, $0.end)) }
        /// The other segment end that sits on the given end, if any.
        func partner(of index: Int, atEnd: Bool) -> (segment: Int, atEnd: Bool)? {
            let position = atEnd ? ends[index].end : ends[index].start
            var best: (segment: Int, atEnd: Bool)?
            var bestDistance: Float = 0.03
            for other in segments.indices where other != index {
                for otherEnd in [false, true] {
                    let distance = simd_distance(position, otherEnd ? ends[other].end : ends[other].start)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = (other, otherEnd)
                    }
                }
            }
            return best
        }

        var visited = [Bool](repeating: false, count: segments.count)
        var bestLoop: [SIMD2<Float>]?
        var bestArea: Float = 0
        for first in segments.indices where !visited[first] {
            var loop: [SIMD2<Float>] = []
            var current = first
            var leavingAtEnd = true
            var closed = false
            while !visited[current] {
                visited[current] = true
                loop.append(leavingAtEnd ? ends[current].end : ends[current].start)
                guard let next = partner(of: current, atEnd: leavingAtEnd) else { break }
                if next.segment == first {
                    closed = !next.atEnd
                    break
                }
                current = next.segment
                leavingAtEnd = !next.atEnd
            }
            let area = abs(signedArea(loop))
            if closed, loop.count >= 3, area > bestArea {
                bestArea = area
                bestLoop = loop
            }
        }
        return bestLoop
    }

    private static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

    private static func contains(_ polygon: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Ear clipping. Returns nil when the polygon crosses itself.
    private static func triangulate(_ polygon: [SIMD2<Float>]) -> [(Int, Int, Int)]? {
        var remaining = Array(polygon.indices)
        if signedArea(polygon) < 0 { remaining.reverse() }
        var triangles: [(Int, Int, Int)] = []
        while remaining.count > 3 {
            let count = remaining.count
            var clipped = false
            for i in 0..<count {
                let ia = remaining[(i + count - 1) % count]
                let ib = remaining[i]
                let ic = remaining[(i + 1) % count]
                let (a, b, c) = (polygon[ia], polygon[ib], polygon[ic])
                guard cross(b - a, c - b) > 1e-7 else { continue }
                let blocked = remaining.contains { index in
                    guard index != ia, index != ib, index != ic else { return false }
                    let p = polygon[index]
                    return cross(b - a, p - a) >= 0 && cross(c - b, p - b) >= 0 && cross(a - c, p - c) >= 0
                }
                if !blocked {
                    triangles.append((ia, ib, ic))
                    remaining.remove(at: i)
                    clipped = true
                    break
                }
            }
            if !clipped { return nil }
        }
        triangles.append((remaining[0], remaining[1], remaining[2]))
        return triangles
    }

    private struct Tile {
        var minU, minV, maxU, maxV: Float
    }

    /// Covers the scanned floor with rectangles on a grid aligned to the room axes.
    /// Enclosed gaps (floor hidden under furniture) are filled.
    private static func floorTiles(
        _ mesh: TriMesh,
        isFloor: [Bool],
        faces: MeshPlanes.Faces,
        axisU: SIMD2<Float>,
        axisV: SIMD2<Float>
    ) -> [Tile] {
        func local(_ p: SIMD3<Float>) -> SIMD2<Float> {
            SIMD2(simd_dot(axisU, SIMD2(p.x, p.z)), simd_dot(axisV, SIMD2(p.x, p.z)))
        }
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for t in isFloor.indices where isFloor[t] {
            let (a, b, c) = mesh.triangle(t)
            for p in [a, b, c] {
                low = simd_min(low, local(p))
                high = simd_max(high, local(p))
            }
        }
        guard high.x > low.x, high.y > low.y else { return [] }
        let cell = max(Float(0.1), simd_reduce_max(high - low) / 768)
        // Two empty cells on every side, so the outside stays connected for the flood fill
        // after the grid has grown by one.
        let width = Int((high.x - low.x) / cell) + 5
        let height = Int((high.y - low.y) / cell) + 5
        let origin = low - 2 * cell
        var filled = [Bool](repeating: false, count: width * height)

        for t in isFloor.indices where isFloor[t] {
            let (a3, b3, c3) = mesh.triangle(t)
            let (a, b, c) = (local(a3), local(b3), local(c3))
            let centre = (a + b + c) / 3
            filled[Int((centre.y - origin.y) / cell) * width + Int((centre.x - origin.x) / cell)] = true
            let triangleLow = simd_min(a, simd_min(b, c))
            let triangleHigh = simd_max(a, simd_max(b, c))
            let sign: Float = cross(b - a, c - a) < 0 ? -1 : 1
            for y in Int((triangleLow.y - origin.y) / cell)...Int((triangleHigh.y - origin.y) / cell) {
                for x in Int((triangleLow.x - origin.x) / cell)...Int((triangleHigh.x - origin.x) / cell) {
                    let p = origin + (SIMD2(Float(x), Float(y)) + 0.5) * cell
                    if sign * cross(b - a, p - a) >= 0, sign * cross(c - b, p - b) >= 0, sign * cross(a - c, p - c) >= 0 {
                        filled[y * width + x] = true
                    }
                }
            }
        }

        // Close one-cell cracks: grow by a cell, fill enclosed gaps, shrink back.
        func neighbours(_ grid: [Bool], _ x: Int, _ y: Int, all: Bool) -> Bool {
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx
                    let ny = y + dy
                    let value = nx >= 0 && ny >= 0 && nx < width && ny < height && grid[ny * width + nx]
                    if all, !value { return false }
                    if !all, value { return true }
                }
            }
            return all
        }
        var grown = filled
        for y in 0..<height {
            for x in 0..<width { grown[y * width + x] = neighbours(filled, x, y, all: false) }
        }
        var outside = [Bool](repeating: false, count: width * height)
        var stack = [0]
        outside[0] = true
        while let index = stack.popLast() {
            let x = index % width
            let y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let neighbour = ny * width + nx
                if !outside[neighbour], !grown[neighbour] {
                    outside[neighbour] = true
                    stack.append(neighbour)
                }
            }
        }
        for i in grown.indices { grown[i] = !outside[i] }
        for y in 0..<height {
            for x in 0..<width { filled[y * width + x] = neighbours(grown, x, y, all: true) }
        }

        // Greedy merge into rectangles.
        var tiles: [Tile] = []
        for y in 0..<height {
            for x in 0..<width where filled[y * width + x] {
                var endX = x
                while endX + 1 < width, filled[y * width + endX + 1] { endX += 1 }
                var endY = y
                rows: while endY + 1 < height {
                    for column in x...endX where !filled[(endY + 1) * width + column] { break rows }
                    endY += 1
                }
                for row in y...endY {
                    for column in x...endX { filled[row * width + column] = false }
                }
                tiles.append(Tile(
                    minU: origin.x + Float(x) * cell, minV: origin.y + Float(y) * cell,
                    maxU: origin.x + Float(endX + 1) * cell, maxV: origin.y + Float(endY + 1) * cell
                ))
            }
        }
        return tiles
    }

    // MARK: Output

    /// Collects flat-shaded triangles. Every face gets its own vertices.
    private struct Builder {
        var mesh = TriMesh()

        /// Adds a triangle, flipped if needed so its normal points along `facing`.
        mutating func addTriangle(_ corners: [SIMD3<Float>], facing: SIMD3<Float>?, kind: MeshClass) {
            var (a, b, c) = (corners[0], corners[1], corners[2])
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 1e-12 else { return }
            normal /= length
            if let facing, simd_dot(normal, facing) < 0 {
                swap(&b, &c)
                normal = -normal
            }
            let base = UInt32(mesh.positions.count)
            mesh.positions.append(contentsOf: [a, b, c])
            mesh.normals.append(contentsOf: [normal, normal, normal])
            mesh.indices.append(contentsOf: [base, base + 1, base + 2])
            mesh.classes.append(kind.rawValue)
        }

        /// Corners in order around the quad.
        mutating func addQuad(_ corners: [SIMD3<Float>], facing: SIMD3<Float>, kind: MeshClass) {
            addTriangle([corners[0], corners[1], corners[2]], facing: facing, kind: kind)
            addTriangle([corners[0], corners[2], corners[3]], facing: facing, kind: kind)
        }

        /// Box given in room axes: x along `axisU`, y up, z along `axisV`.
        mutating func addBox(low: SIMD3<Float>, high: SIMD3<Float>, axisU: SIMD2<Float>, axisV: SIMD2<Float>, kind: MeshClass) {
            func world(_ p: SIMD3<Float>) -> SIMD3<Float> {
                let flat = axisU * p.x + axisV * p.z
                return SIMD3(flat.x, p.y, flat.y)
            }
            func direction(_ d: SIMD3<Float>) -> SIMD3<Float> { world(d) }
            for axis in 0..<3 {
                let other = (axis + 1) % 3
                let third = (axis + 2) % 3
                for side in [low, high] {
                    var corners: [SIMD3<Float>] = []
                    for (useHighOther, useHighThird) in [(false, false), (true, false), (true, true), (false, true)] {
                        var corner = SIMD3<Float>.zero
                        corner[axis] = side[axis]
                        corner[other] = useHighOther ? high[other] : low[other]
                        corner[third] = useHighThird ? high[third] : low[third]
                        corners.append(world(corner))
                    }
                    var outward = SIMD3<Float>.zero
                    outward[axis] = side == low ? -1 : 1
                    addQuad(corners, facing: direction(outward), kind: kind)
                }
            }
        }
    }
}
