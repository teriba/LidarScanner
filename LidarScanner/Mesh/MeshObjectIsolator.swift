import Foundation
import simd

enum MeshObjectError: LocalizedError {
    case nothingLeft

    var errorDescription: String? {
        "No object found. Nothing was left after removing the floor and walls."
    }
}

/// Cuts a single object out of a cleaned scan mesh: removes the surface it stands on
/// and the walls, then keeps one connected piece.
enum MeshObjectIsolator {
    enum Pick {
        /// The piece closest to the middle of the scan.
        case nearestCentre
        case largest
    }

    struct Options {
        var pick: Pick = .nearestCentre
        var targetTriangles = 60_000
        /// Holes with a shorter outline are closed. Zero turns hole filling off.
        var maxHolePerimeter: Float = 0.4
        /// Moves the object so it stands on the origin.
        var recentre = true
    }

    struct Object {
        var mesh = TriMesh()
        /// Height of the removed support surface in the source mesh, if one was found.
        var supportHeight: Float?
        var removedWalls = 0
        var filledHoles = 0
    }

    static func isolate(from mesh: TriMesh, options: Options = Options()) throws -> Object {
        let faces = MeshPlanes.Faces(mesh)
        let faceCount = mesh.triangleCount
        let classed = mesh.hasClasses
        func faceClass(_ t: Int) -> MeshClass { classed ? MeshClass(rawValue: mesh.classes[t]) ?? .none : .none }

        // The user walks around the object, so the scan's centre of area is near it.
        var totalArea: Float = 0
        var weighted = SIMD3<Float>.zero
        for t in 0..<faceCount {
            totalArea += faces.areas[t]
            weighted += faces.areas[t] * faces.centroids[t]
        }
        guard totalArea > 0 else { throw MeshObjectError.nothingLeft }
        let centre = weighted / totalArea

        // Walls must be big, so the flat side of a cabinet does not count.
        var wallOptions = MeshPlanes.WallOptions()
        wallOptions.minArea = 1.5
        wallOptions.minHeight = 1.2
        let detected = MeshPlanes.walls(mesh, faces: faces, select: { t in
            guard classed else { return true }
            let kind = faceClass(t)
            return kind == .wall || kind == .window || kind == .door
        }, options: wallOptions)
        let wallOfFace = detected.wallOfFace

        let support = supportHeight(faces: faces, wallOfFace: wallOfFace, centre: centre) { t in
            // A seat is part of the object, never the thing it stands on.
            faceClass(t) != .seat && faceClass(t) != .ceiling
        }

        // Ceiling: the highest large downward-facing level well above the support.
        let ceilingLevels = MeshPlanes.levels(faces) {
            faces.isDownward($0) && faces.centroids[$0].y > (support ?? centre.y) + 1.5
        }
        let largestCeiling = ceilingLevels.map(\.area).max() ?? 0
        let ceiling = ceilingLevels.last { $0.area >= max(0.3, 0.2 * largestCeiling) }?.height

        var keep = [Bool](repeating: true, count: faceCount)
        for t in 0..<faceCount {
            if wallOfFace[t] >= 0 { keep[t] = false }
            // Everything at or below the support goes: the surface itself, table legs, the floor under a table.
            if let support, faces.centroids[t].y <= support + 0.03 { keep[t] = false }
            if let ceiling, faces.centroids[t].y >= ceiling - 0.08 { keep[t] = false }
            if classed, faceClass(t) == .ceiling { keep[t] = false }
        }

        let (labels, count) = MeshProcessing.componentLabels(mesh, include: keep)
        let stats = MeshProcessing.componentStats(mesh, labels: labels, count: count)
        guard let largest = stats.map(\.triangles).max(), largest > 0 else { throw MeshObjectError.nothingLeft }
        // Scan noise leaves crumbs. Only pieces of some size can win.
        let eligible = stats.indices.filter { stats[$0].triangles >= max(20, largest / 20) || stats[$0].triangles == largest }
        func distanceToCentre(_ component: MeshProcessing.Component) -> Float {
            let nearest = simd_clamp(centre, component.min, component.max)
            return simd_length(SIMD2(nearest.x - centre.x, nearest.z - centre.z))
        }
        let chosen: Int?
        switch options.pick {
        case .largest:
            chosen = eligible.max { stats[$0].triangles < stats[$1].triangles }
        case .nearestCentre:
            chosen = eligible.min {
                let (a, b) = (distanceToCentre(stats[$0]), distanceToCentre(stats[$1]))
                return a != b ? a < b : stats[$0].triangles > stats[$1].triangles
            }
        }
        guard let chosen else { throw MeshObjectError.nothingLeft }

        var object = Object(supportHeight: support, removedWalls: detected.walls.count)
        var result = MeshProcessing.filtered(mesh, keep: labels.map { $0 == Int32(chosen) })
        result = MeshProcessing.decimate(result, targetTriangles: options.targetTriangles)
        if options.maxHolePerimeter > 0 {
            object.filledHoles = MeshProcessing.fillSmallHoles(&result, maxPerimeter: options.maxHolePerimeter)
        }
        if options.recentre {
            let bounds = result.bounds
            let offset = SIMD3((bounds.min.x + bounds.max.x) / 2, bounds.min.y, (bounds.min.z + bounds.max.z) / 2)
            for i in result.positions.indices { result.positions[i] -= offset }
        }
        MeshProcessing.recomputeNormals(&result)
        object.mesh = result
        return object
    }

    /// Picks the horizontal surface the object stands on: the highest level under the
    /// scan centre that has something on top of it. Falls back to the largest level.
    private static func supportHeight(
        faces: MeshPlanes.Faces,
        wallOfFace: [Int32],
        centre: SIMD3<Float>,
        select: (Int) -> Bool
    ) -> Float? {
        let levels = MeshPlanes.levels(faces, select: { faces.isUpward($0) && wallOfFace[$0] < 0 && select($0) })
        guard let largest = levels.max(by: { $0.area < $1.area }) else { return nil }
        let candidates = levels.filter { $0.area >= max(0.05, 0.1 * largest.area) }

        var best: Float?
        for level in candidates {
            // Footprint of the level in XZ.
            var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for t in faces.areas.indices where faces.isUpward(t) && abs(faces.centroids[t].y - level.height) <= 0.04 {
                let p = SIMD2(faces.centroids[t].x, faces.centroids[t].z)
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
            let margin: Float = 0.3
            guard centre.x >= low.x - margin, centre.x <= high.x + margin,
                  centre.z >= low.y - margin, centre.z <= high.y + margin else { continue }

            var areaAbove: Float = 0
            // Downward faces are skipped, or the ceiling would count as standing on a cabinet top.
            for t in faces.areas.indices where wallOfFace[t] < 0 && !faces.isDownward(t) {
                let p = faces.centroids[t]
                if p.y > level.height + 0.04, p.y < level.height + 2,
                   p.x >= low.x, p.x <= high.x, p.z >= low.y, p.z <= high.y {
                    areaAbove += faces.areas[t]
                }
            }
            if areaAbove >= max(0.02, 0.03 * level.area), level.height > best ?? -.greatestFiniteMagnitude {
                best = level.height
            }
        }
        return best ?? largest.height
    }
}
