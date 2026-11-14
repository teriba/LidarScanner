import ARKit
import Foundation
import Observation
import RealityKit
import RoomPlan
import SwiftUI // ObjectCaptureSession lives in the RealityKit + SwiftUI overlay

enum ScanKind: String, CaseIterable, Identifiable {
    case object
    case room
    case mesh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: "Object"
        case .room: "Room"
        case .mesh: "Mesh"
        }
    }

    var sectionTitle: String {
        switch self {
        case .object: "Objects"
        case .room: "Rooms (floor plan model)"
        case .mesh: "Raw meshes"
        }
    }

    var menuTitle: String {
        switch self {
        case .object: "Scan object"
        case .room: "Scan room"
        case .mesh: "Scan raw mesh"
        }
    }

    var systemImage: String {
        switch self {
        case .object: "cube.transparent"
        case .room: "square.split.bottomrightquarter"
        case .mesh: "skew"
        }
    }

    var fileExtension: String {
        switch self {
        case .object, .room: "usdz"
        case .mesh: "obj"
        }
    }

    @MainActor
    var isSupported: Bool {
        switch self {
        case .object: ObjectCaptureSession.isSupported
        case .room: RoomCaptureSession.isSupported
        case .mesh: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }
}

struct SavedScan: Identifiable, Hashable {
    let url: URL
    let kind: ScanKind
    let date: Date
    let byteCount: Int64

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Saved scans live in Documents/Scans/<Kind>/, which is also visible in the Files app.
@MainActor
@Observable
final class ScanStore {
    private(set) var scans: [SavedScan] = []

    private static let root = URL.documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory)

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    static func folder(for kind: ScanKind) -> URL {
        root.appending(path: kind.title, directoryHint: .isDirectory)
    }

    func newFileURL(for kind: ScanKind) -> URL {
        let folder = Self.folder(for: kind)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(kind.title) \(Self.nameFormatter.string(from: .now))"
        return folder.appending(path: name).appendingPathExtension(kind.fileExtension)
    }

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        var found: [SavedScan] = []
        for kind in ScanKind.allCases {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: Self.folder(for: kind),
                includingPropertiesForKeys: keys,
                options: .skipsHiddenFiles
            )) ?? []
            for url in files where url.pathExtension.lowercased() == kind.fileExtension {
                let values = try? url.resourceValues(forKeys: Set(keys))
                found.append(SavedScan(
                    url: url,
                    kind: kind,
                    date: values?.creationDate ?? .distantPast,
                    byteCount: Int64(values?.fileSize ?? 0)
                ))
            }
        }
        scans = found.sorted { $0.date > $1.date }
    }

    func delete(_ scan: SavedScan) {
        try? FileManager.default.removeItem(at: scan.url)
        reload()
    }
}
