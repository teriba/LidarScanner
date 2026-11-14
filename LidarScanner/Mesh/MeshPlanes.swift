import Foundation
import simd

/// Plane detection shared by the room and object conversions. Gravity is -Y.
enum MeshPlanes {
    /// Per-triangle centroid, unit normal and area.
    struct Faces {
        var centroids: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var areas: [Float]

        init(_ mesh: TriMesh) {
            let count = mesh.triangleCount
            centroids = []
            normals = []
            areas = []
            centroids.reserveCapacity(count)
            normals.reserveCapacity(count)
            areas.reserveCapacity(count)
            for t in 0..<count {
                let (a, b, c) = mesh.triangle(t)
                let cross = simd_cross(b - a, c - a)
                let length = simd_length(cross)
                centroids.append((a + b + c) / 3)
                normals.append(length > 1e-12 ? cross / length : .zero)
                areas.append(length / 2)
            }
        }

        func isUpward(_ t: Int) -> Bool { normals[t].y > 0.85 }
        func isDownward(_ t: Int) -> Bool { normals[t].y < -0.85 }
        /// Slivers are left out. Their normals are noise.
        func isVertical(_ t: Int) -> Bool { abs(normals[t].y) < 0.3 && areas[t] > 2e-5 }
    }

    // MARK: Horizontal levels

    /// A horizontal surface found as a peak in the height histogram.
    struct Level {
        var height: Float
        var area: Float
    }

    /// Heights where the selected faces concentrate, lowest first.
    static func levels(_ faces: Faces, select: (Int) -> Bool, minArea: Float = 0.02) -> [Level] {
        let bin: Float = 0.02
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        var selected: [Int32] = []
        for t in faces.areas.indices where select(t) {
            selected.append(Int32(t))
            low = min(low, faces.centroids[t].y)
            high = max(high, faces.centroids[t].y)
        }
        guard !selected.isEmpty else { return [] }
        let count = min(Int((high - low) / bin) + 1, 20_000)
        var area = [Float](repeating: 0, count: count)
        var moment = [Float](repeating: 0, count: count)
        for t in selected {
            let y = faces.centroids[Int(t)].y
            let index = min(Int((y - low) / bin), count - 1)
            area[index] += faces.areas[Int(t)]
            moment[index] += faces.areas[Int(t)] * y
        }
        // Scan noise spreads one surface over a few bins, so compare 10 cm windows.
        let reach = 2
        func window(_ values: [Float], _ centre: Int) -> Float {
            var sum: Float = 0
            for i in max(0, centre - reach)...min(count - 1, centre + reach) { sum += values[i] }
            return sum
        }
        let windowed = (0..<count).map { window(area, $0) }
        var result: [Level] = []
        for i in 0..<count where windowed[i] >= minArea {
            var isPeak = true
            for j in max(0, i - 2 * reach)...min(count - 1, i + 2 * reach) where j != i {
                if windowed[j] > windowed[i] || (windowed[j] == windowed[i] && j < i) { isPeak = false }
            }
            if isPeak {
                result.append(Level(height: window(moment, i) / windowed[i], area: windowed[i]))
            }
        }
        return result
    }

    // MARK: Walls

    /// A vertical plane: all points p with dot(normal, p.xz) == offset.
    struct Wall {
        /// Unit normal in the XZ plane, pointing away from the surface (into the room).
        var normal: SIMD2<Float>
        var offset: Float
        var area: Float
        var minY: Float
        var maxY: Float

        /// Direction along the wall in XZ.
        var tangent: SIMD2<Float> { SIMD2(-normal.y, normal.x) }

        func distance(_ p: SIMD3<Float>) -> Float { simd_dot(normal, SIMD2(p.x, p.z)) - offset }
    }

    struct WallOptions {
        var minArea: Float = 0.6
        var minHeight: Float = 1.0
        var maxWalls = 48
        /// Largest distance from the plane for a face to count as part of it.
        var distanceTolerance: Float = 0.06
    }

    /// Finds vertical planes with a Hough vote over (direction, offset), largest first.
    /// `wallOfFace` holds the wall index per triangle, or -1.
    static func walls(
        _ mesh: TriMesh,
        faces: Faces,
        select: (Int) -> Bool,
        options: WallOptions = WallOptions()
    ) -> (walls: [Wall], wallOfFace: [Int32]) {
        let faceCount = mesh.triangleCount
        var wallOfFace = [Int32](repeating: -1, count: faceCount)
        let candidates = (0..<faceCount).filter { faces.isVertical($0) && select($0) }
        guard !candidates.isEmpty else { return ([], wallOfFace) }

        let bounds = mesh.bounds
        let centre = SIMD2((bounds.min.x + bounds.max.x) / 2, (bounds.min.z + bounds.max.z) / 2)
        let radius = simd_length(SIMD2(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z)) / 2 + 0.1
        let angleBins = 90
        let offsetStep = max(Float(0.04), radius / 1500)
        let offsetBins = Int(2 * radius / offsetStep) + 1

        // Direction is folded into [0, π). The offset sign carries the rest.
        func foldedDirection(_ t: Int) -> (angle: Float, offset: Float) {
            let n = faces.normals[t]
            var angle = atan2(n.z, n.x)
            if angle < 0 { angle += .pi }
            if angle >= .pi { angle -= .pi }
            let p = SIMD2(faces.centroids[t].x, faces.centroids[t].z) - centre
            return (angle, cos(angle) * p.x + sin(angle) * p.y)
        }

        var votes = [Float](repeating: 0, count: angleBins * offsetBins)
        var binOfFace = [Int32](repeating: -1, count: faceCount)
        for t in candidates {
            let (angle, offset) = foldedDirection(t)
            let a = min(Int(angle / .pi * Float(angleBins)), angleBins - 1)
            let o = min(max(Int((offset + radius) / offsetStep), 0), offsetBins - 1)
            binOfFace[t] = Int32(a * offsetBins + o)
            votes[a * offsetBins + o] += faces.areas[t]
        }
        // Stepping past either end of the angle axis flips the normal, which mirrors the offset.
        func vote(_ a: Int, _ o: Int) -> Float {
            var a = a
            var o = o
            if a < 0 {
                a += angleBins
                o = offsetBins - 1 - o
            } else if a >= angleBins {
                a -= angleBins
                o = offsetBins - 1 - o
            }
            guard o >= 0, o < offsetBins else { return 0 }
            return votes[a * offsetBins + o]
        }

        var used = [Bool](repeating: false, count: faceCount)
        var found: [Wall] = []
        var attempts = 0
        while found.count < options.maxWalls, attempts < options.maxWalls * 3 {
            attempts += 1
            var bestScore: Float = 0
            var best = (a: 0, o: 0)
            for a in 0..<angleBins {
                for o in 0..<offsetBins where votes[a * offsetBins + o] > 0 {
                    var score: Float = 0
                    for da in -1...1 {
                        for d in -1...1 { score += vote(a + da, o + d) }
                    }
                    if score > bestScore {
                        bestScore = score
                        best = (a, o)
                    }
                }
            }
            guard bestScore >= options.minArea * 0.4 else { break }

            let angle = (Float(best.a) + 0.5) / Float(angleBins) * .pi
            var normal = SIMD2(cos(angle), sin(angle))
            var offset = (Float(best.o) + 0.5) * offsetStep - radius + simd_dot(normal, centre)

            func inliers(angleCos: Float, tolerance: Float) -> [Int] {
                candidates.filter { t in
                    guard !used[t] else { return false }
                    let n = faces.normals[t]
                    let horizontal = SIMD2(n.x, n.z)
                    let length = simd_length(horizontal)
                    guard length > 0, abs(simd_dot(horizontal, normal)) / length >= angleCos else { return false }
                    let p = SIMD2(faces.centroids[t].x, faces.centroids[t].z)
                    return abs(simd_dot(normal, p) - offset) <= tolerance
                }
            }

            var members = inliers(angleCos: cos(.pi / 8), tolerance: options.distanceTolerance * 1.5)
            // A narrow strip of wall gives an unstable fit, so only accept one close to the vote.
            if let fit = fitLine(members, faces: faces), abs(simd_dot(fit.normal, normal)) > 0.94 {
                let sign: Float = simd_dot(fit.normal, normal) < 0 ? -1 : 1
                normal = sign * fit.normal
                offset = sign * fit.offset
                members = inliers(angleCos: cos(.pi / 9), tolerance: options.distanceTolerance)
            }
            guard !members.isEmpty else {
                // Nothing matched the peak. Clear it so the search moves on.
                votes[best.a * offsetBins + best.o] = 0
                continue
            }

            var area: Float = 0
            var facing: Float = 0
            for t in members {
                used[t] = true
                votes[Int(binOfFace[t])] -= faces.areas[t]
                area += faces.areas[t]
                facing += faces.areas[t] * simd_dot(SIMD2(faces.normals[t].x, faces.normals[t].z), normal)
            }
            let (minY, maxY) = verticalExtent(members, faces: faces)
            guard area >= options.minArea, maxY - minY >= options.minHeight else { continue }
            if facing < 0 {
                normal = -normal
                offset = -offset
            }
            for t in members { wallOfFace[t] = Int32(found.count) }
            found.append(Wall(normal: normal, offset: offset, area: area, minY: minY, maxY: maxY))
        }

        // Largest first, keeping wallOfFace in step.
        let order = found.indices.sorted { found[$0].area > found[$1].area }
        var newIndex = [Int32](repeating: 0, count: found.count)
        for (position, old) in order.enumerated() { newIndex[old] = Int32(position) }
        for t in candidates where wallOfFace[t] >= 0 { wallOfFace[t] = newIndex[Int(wallOfFace[t])] }
        return (order.map { found[$0] }, wallOfFace)
    }

    /// Height range that holds the bulk of the faces. A few stray faces far above or
    /// below do not stretch it.
    private static func verticalExtent(_ members: [Int], faces: Faces) -> (Float, Float) {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        var total: Float = 0
        for t in members {
            low = min(low, faces.centroids[t].y)
            high = max(high, faces.centroids[t].y)
            total += faces.areas[t]
        }
        let step: Float = 0.1
        let count = Int((high - low) / step) + 1
        var area = [Float](repeating: 0, count: count)
        for t in members { area[min(Int((faces.centroids[t].y - low) / step), count - 1)] += faces.areas[t] }
        let threshold = 0.25 * total / Float(count)
        guard let first = area.firstIndex(where: { $0 >= threshold }),
              let last = area.lastIndex(where: { $0 >= threshold }) else { return (low, high) }
        return (low + Float(first) * step, min(low + Float(last + 1) * step, high))
    }

    /// Area-weighted total least squares line through the face centroids in XZ.
    private static func fitLine(_ members: [Int], faces: Faces) -> (normal: SIMD2<Float>, offset: Float)? {
        var weight: Float = 0
        var mean = SIMD2<Float>.zero
        for t in members {
            weight += faces.areas[t]
            mean += faces.areas[t] * SIMD2(faces.centroids[t].x, faces.centroids[t].z)
        }
        guard weight > 0 else { return nil }
        mean /= weight
        var xx: Float = 0
        var xz: Float = 0
        var zz: Float = 0
        for t in members {
            let d = SIMD2(faces.centroids[t].x, faces.centroids[t].z) - mean
            xx += faces.areas[t] * d.x * d.x
            xz += faces.areas[t] * d.x * d.y
            zz += faces.areas[t] * d.y * d.y
        }
        // The line runs along the major axis of the covariance. The normal is perpendicular to it.
        let along = 0.5 * atan2(2 * xz, xx - zz)
        let normal = SIMD2(-sin(along), cos(along))
        return (normal, simd_dot(normal, mean))
    }
}
