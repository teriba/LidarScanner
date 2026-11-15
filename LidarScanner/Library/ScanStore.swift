import ARKit
import Foundation
import Observation
import RealityKit
import RoomPlan
import SwiftUI // ObjectCaptureSession lives in the RealityKit + SwiftUI overlay

enum ScanKind: String, CaseIterable, Identifiable {
    case object
    case room
    case detailed
    case mesh
    case face

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: "Object"
        case .room: "Room"
        case .detailed: "Detailed room"
        case .mesh: "Mesh"
        case .face: "Face"
        }
    }

    var sectionTitle: String {
        switch self {
        case .object: "Objects"
        case .room: "Rooms (floor plan model)"
        case .detailed: "Detailed rooms (floor plan with scanned furniture)"
        case .mesh: "Raw meshes"
        case .face: "Faces"
        }
    }

    var menuTitle: String {
        switch self {
        case .object: "Scan object"
        case .room: "Scan room"
        case .detailed: "Scan detailed room"
        case .mesh: "Scan raw mesh"
        case .face: "Scan face"
        }
    }

    var systemImage: String {
        switch self {
        case .object: "cube.transparent"
        case .room: "square.split.bottomrightquarter"
        case .detailed: "sofa"
        case .mesh: "skew"
        case .face: "face.smiling"
        }
    }

    var fileExtension: String {
        switch self {
        case .object, .room, .detailed, .face: "usdz"
        case .mesh: "obj"
        }
    }

    /// Extensions listed in this kind's folder. Scans made by the app use `fileExtension`.
    /// Rooms and objects converted from a raw mesh are OBJ.
    var readableExtensions: Set<String> {
        switch self {
        case .object, .room: ["usdz", "obj"]
        case .mesh: ["obj"]
        case .detailed, .face: ["usdz"]
        }
    }

    @MainActor
    var isSupported: Bool {
        switch self {
        case .object: ObjectCaptureSession.isSupported
        case .room: RoomCaptureSession.isSupported
        case .detailed:
            RoomCaptureSession.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        case .mesh: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        case .face: ARFaceTrackingConfiguration.isSupported
        }
    }
}

extension MeshConversion {
    /// Section of the library the result is saved in.
    var resultKind: ScanKind {
        switch self {
        case .cleanUp: .mesh
        case .room: .room
        case .object: .object
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
/// A detailed room also has a `<name>.detail` folder next to its USDZ, see DetailedRoomPackage.
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
        newFileURL(for: kind, prefix: kind.title, fileExtension: kind.fileExtension)
    }

    private func newFileURL(for kind: ScanKind, prefix: String, fileExtension: String) -> URL {
        let folder = Self.folder(for: kind)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(prefix) \(Self.nameFormatter.string(from: .now))"
        return folder.appending(path: name).appendingPathExtension(fileExtension)
    }

    /// Where the result of a mesh conversion goes. Always a new file.
    func newFileURL(forResultOf conversion: MeshConversion) -> URL {
        newFileURL(for: conversion.resultKind, prefix: conversion.filePrefix, fileExtension: "obj")
    }

    /// Where an edited detailed room goes. Always a new file.
    func newEditedRoomURL() -> URL {
        newFileURL(for: .detailed, prefix: "Detailed room edited", fileExtension: "usdz")
    }

    /// Looks up a file that was just written, after a reload.
    func scan(at url: URL) -> SavedScan? {
        // Compared by folder and file name. Directory listings can spell the same path differently.
        let folder = url.deletingLastPathComponent().lastPathComponent
        return scans.first { $0.url.lastPathComponent == url.lastPathComponent && $0.kind.title == folder }
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
            for url in files where kind.readableExtensions.contains(url.pathExtension.lowercased()) {
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
        if scan.kind == .detailed {
            try? FileManager.default.removeItem(at: DetailedRoomPackage(model: scan.url).folder)
        }
        reload()
    }
}
