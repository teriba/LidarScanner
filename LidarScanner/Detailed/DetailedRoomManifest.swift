import Foundation
import simd

/// Contents and edit state of a detailed room. Stored as `manifest.json` in the
/// scan's sidecar folder, so the room can be opened and edited again.
struct DetailedRoomManifest: Codable, Equatable {
    enum Display: String, Codable {
        /// The cut-out scan mesh.
        case mesh
        /// The plain RoomPlan box.
        case box
        /// An object scan placed on the box.
        case replacement
    }

    struct Replacement: Codable, Equatable {
        /// File name in the sidecar's `replacements` folder.
        var file: String
        /// Name shown in the editor.
        var title: String
        /// Scale the model to fit the box. Off keeps its real size.
        var fitToBox = false
        /// Extra rotation in 90 degree steps.
        var quarterTurns = 0
        /// Offset in metres along the box axes.
        var nudge: [Float] = [0, 0, 0]

        var nudgeVector: SIMD3<Float> {
            nudge.count == 3 ? SIMD3(nudge[0], nudge[1], nudge[2]) : .zero
        }
    }

    struct Item: Codable, Equatable, Identifiable {
        /// Node name: category plus the RoomPlan object UUID without dashes.
        let id: String
        let uuid: UUID
        let category: String
        let pose: BoxPose
        /// Flat sRGB colour for the box. Nil if the camera never saw it.
        var color: [Float]?
        /// False when the scan had too little mesh inside the box.
        var hasMesh: Bool
        var display: Display
        var replacement: Replacement?

        static func nodeName(category: String, uuid: UUID) -> String {
            "\(category)_\(uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        }
    }

    var version = 1
    var floorY: Float?
    var items: [Item] = []
    /// Scan mesh outside every box that is not wall, floor or ceiling.
    var hasLooseDetail = false
    var showLooseDetail = false
}

/// File layout of a detailed room: `<name>.usdz` for viewing and sharing, and a folder
/// `<name>.detail` next to it with everything needed to edit.
struct DetailedRoomPackage {
    static let looseDetailName = "loose_detail"

    let folder: URL

    init(folder: URL) { self.folder = folder }

    /// The sidecar folder that belongs to a USDZ.
    init(model: URL) {
        folder = model.deletingPathExtension().appendingPathExtension("detail")
    }

    var exists: Bool { FileManager.default.fileExists(atPath: manifestURL.path) }

    var manifestURL: URL { folder.appending(path: "manifest.json") }
    /// The encoded RoomPlan CapturedRoom.
    var roomURL: URL { folder.appending(path: "room.json") }
    /// The raw scan mesh with face classes.
    var rawMeshURL: URL { folder.appending(path: "mesh.obj") }
    /// Walls, floor, doors and windows from RoomPlan, without furniture.
    var structureURL: URL { folder.appending(path: "structure.usdz") }
    var replacementsFolder: URL { folder.appending(path: "replacements", directoryHint: .isDirectory) }

    func meshURL(_ name: String) -> URL { folder.appending(path: "\(name).lspm") }
    func textureURL(_ name: String) -> URL { folder.appending(path: "\(name).png") }
    func replacementURL(_ file: String) -> URL { replacementsFolder.appending(path: file) }

    func readManifest() throws -> DetailedRoomManifest {
        try JSONDecoder().decode(DetailedRoomManifest.self, from: Data(contentsOf: manifestURL))
    }

    func write(_ manifest: DetailedRoomManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }
}
