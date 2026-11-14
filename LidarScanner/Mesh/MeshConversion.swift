import Foundation

/// The conversions offered for a raw mesh scan. Each reads an OBJ and writes a new one.
enum MeshConversion: String, CaseIterable, Identifiable {
    case cleanUp
    case room
    case object

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanUp: "Clean up"
        case .room: "Convert to room"
        case .object: "Convert to object"
        }
    }

    var systemImage: String {
        switch self {
        case .cleanUp: "wand.and.stars"
        case .room: "square.split.bottomrightquarter"
        case .object: "cube.transparent"
        }
    }

    /// Start of the result's file name.
    var filePrefix: String {
        switch self {
        case .cleanUp: "Mesh cleaned"
        case .room: "Room from mesh"
        case .object: "Object from mesh"
        }
    }

    /// Runs the conversion. Blocking, so call it off the main thread.
    /// `input` is never modified. `output` appears only when the whole run succeeds.
    func run(input: URL, output: URL, progress: @escaping (Double, String) -> Void) throws {
        progress(0, "Reading mesh")
        var mesh = try OBJFile.read(input) { progress($0 * 0.3, "Reading mesh") }
        try Task.checkCancellation()

        var options = MeshProcessing.CleanOptions()
        switch self {
        case .cleanUp:
            break
        case .room:
            // Plane fitting only needs a coarse mesh.
            options.maxTriangles = 150_000
        case .object:
            // Keep detail here. The object is decimated after it has been cut out.
            options.targetRatio = 1
            options.maxTriangles = 400_000
        }
        mesh = MeshProcessing.cleaned(mesh, options: options) { progress(0.3 + $0 * 0.35, "Cleaning up") }
        try Task.checkCancellation()

        switch self {
        case .cleanUp:
            break
        case .room:
            progress(0.65, "Finding floor and walls")
            mesh = try MeshRoomBuilder.build(from: mesh).mesh
        case .object:
            progress(0.65, "Isolating object")
            mesh = try MeshObjectIsolator.isolate(from: mesh).mesh
        }
        try Task.checkCancellation()

        progress(0.85, "Saving")
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("obj")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try OBJFile.write(mesh, to: temporary) { progress(0.85 + $0 * 0.15, "Saving") }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        progress(1, "Saving")
    }
}
