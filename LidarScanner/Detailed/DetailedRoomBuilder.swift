import Foundation
import RoomPlan
import simd

/// Combines a RoomPlan room with the raw mesh from the same session. Walls, floor,
/// doors and windows stay RoomPlan geometry. Each furniture box is replaced by the
/// scan mesh inside it, coloured from the camera keyframes.
enum DetailedRoomBuilder {
    struct Options {
        var crop = DetailCrop.Options()
        var maxTrianglesPerObject = 12_000
        var maxLooseTriangles = 40_000
        /// Show scan mesh outside the boxes (lamps, plants, clutter) from the start.
        /// It is noisy, so it is off. The mesh is saved either way and can be shown in the editor.
        var showLooseDetail = false
    }

    /// Blocking, so call it off the main thread. Writes the USDZ at `output` and the
    /// sidecar folder next to it. Nothing is left behind if it fails.
    static func build(
        room: CapturedRoom,
        mesh: TriMesh,
        keyframes: [RoomKeyframe],
        output: URL,
        options: Options = Options(),
        progress: @escaping (Double, String) -> Void
    ) throws {
        let package = DetailedRoomPackage(model: output)
        let files = FileManager.default
        try? files.removeItem(at: package.folder)
        try files.createDirectory(at: package.folder, withIntermediateDirectories: true)
        do {
            try fill(package, room: room, mesh: mesh, keyframes: keyframes, options: options, progress: progress)
            progress(0.9, "Writing model")
            try DetailedRoomScene.export(package: package, manifest: package.readManifest(), to: output)
            progress(1, "Writing model")
        } catch {
            try? files.removeItem(at: package.folder)
            try? files.removeItem(at: output)
            throw error
        }
    }

    private static func fill(
        _ package: DetailedRoomPackage,
        room: CapturedRoom,
        mesh: TriMesh,
        keyframes: [RoomKeyframe],
        options: Options,
        progress: (Double, String) -> Void
    ) throws {
        progress(0, "Saving scan data")
        try JSONEncoder().encode(room).write(to: package.roomURL, options: .atomic)
        if mesh.triangleCount > 0 {
            try OBJFile.write(mesh, to: package.rawMeshURL) { progress($0 * 0.15, "Saving scan data") }
        }
        try Task.checkCancellation()

        // Structure: the RoomPlan export, coloured, with the furniture boxes taken out.
        progress(0.15, "Colouring walls")
        try room.export(to: package.structureURL, exportOptions: .parametric)
        let elements = RoomColorizer.elements(of: room)
        let firstObject = elements.count - room.objects.count
        try RoomColorizer.colorize(
            usdzAt: package.structureURL,
            elements: elements,
            keyframes: keyframes,
            removing: Set(firstObject..<elements.count)
        )
        let boxColors = RoomColorizer.colors(of: Array(elements[firstObject...]), keyframes: keyframes)
        try Task.checkCancellation()

        progress(0.25, "Cutting out furniture")
        let surfaces = room.walls + room.doors + room.windows + room.openings
        let walls = surfaces.map { BoxPose(transform: $0.transform, dimensions: $0.dimensions) }
        let boxes = room.objects.map { BoxPose(transform: $0.transform, dimensions: $0.dimensions) }
        let floorY = room.floors.map { $0.transform.columns.3.y }.min()
            ?? walls.map(\.bottomY).min()
        let owners = DetailCrop.owners(of: mesh, boxes: boxes, walls: walls, floorY: floorY, options: options.crop)

        var manifest = DetailedRoomManifest()
        manifest.floorY = floorY
        manifest.showLooseDetail = options.showLooseDetail
        for (index, object) in room.objects.enumerated() {
            try Task.checkCancellation()
            progress(0.3 + 0.5 * Double(index) / Double(max(boxes.count, 1)), "Cutting out furniture")
            let category = String(describing: object.category)
            let id = DetailedRoomManifest.Item.nodeName(category: category, uuid: object.identifier)
            let color = boxColors[index]
            let hasMesh = try writePiece(
                DetailCrop.submesh(mesh, owners: owners, owner: Int32(index)),
                name: id,
                maxTriangles: options.maxTrianglesPerObject,
                fallback: color,
                keyframes: keyframes,
                package: package
            )
            manifest.items.append(DetailedRoomManifest.Item(
                id: id,
                uuid: object.identifier,
                category: category,
                pose: boxes[index],
                color: color.map { [$0.x, $0.y, $0.z] },
                hasMesh: hasMesh,
                display: hasMesh ? .mesh : .box,
                replacement: nil
            ))
        }

        progress(0.8, "Other detail")
        manifest.hasLooseDetail = try writePiece(
            DetailCrop.submesh(mesh, owners: owners, owner: DetailCrop.loose),
            name: DetailedRoomPackage.looseDetailName,
            maxTriangles: options.maxLooseTriangles,
            fallback: nil,
            keyframes: keyframes,
            package: package
        )
        try package.write(manifest)
    }

    /// Cleans, colours and saves one piece of the scan. False if there is too little of it.
    private static func writePiece(
        _ piece: TriMesh,
        name: String,
        maxTriangles: Int,
        fallback: SIMD3<Float>?,
        keyframes: [RoomKeyframe],
        package: DetailedRoomPackage
    ) throws -> Bool {
        guard let cleaned = DetailCrop.cleaned(piece, maxTriangles: maxTriangles) else { return false }
        let seen = DetailColor.vertexColors(of: cleaned, keyframes: keyframes)
        // The fallback is sRGB, vertex colours are linear. Mid grey when there is none.
        let grey = SIMD3<Float>(repeating: 0.45)
        let linearFallback = fallback.map { sRGB in
            SIMD3<Float>(
                KeyframeSampler.sRGBToLinear(UInt8((sRGB.x * 255).rounded())),
                KeyframeSampler.sRGBToLinear(UInt8((sRGB.y * 255).rounded())),
                KeyframeSampler.sRGBToLinear(UInt8((sRGB.z * 255).rounded()))
            )
        } ?? grey
        let colors = DetailColor.filled(seen, mesh: cleaned, fallback: linearFallback)
        let palette = PaletteMesh(mesh: cleaned, colors: colors)
        try palette.write(to: package.meshURL(name))
        try DetailedRoomScene.writeTexture(palette, to: package.textureURL(name))
        return true
    }
}
