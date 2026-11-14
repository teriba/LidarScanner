import CoreGraphics
import Foundation
import ImageIO
import SceneKit
import UniformTypeIdentifiers
import simd

/// Writes a textured face mesh as USDZ. Uses SceneKit and ImageIO only, so it also
/// compiles on macOS for testing.
enum FaceModelWriter {
    enum WriteError: LocalizedError {
        case emptyMesh
        case textureFailed
        case exportFailed
        case textureMissing

        var errorDescription: String? {
            switch self {
            case .emptyMesh: "The face mesh is empty."
            case .textureFailed: "Could not save the face texture."
            case .exportFailed: "Could not write the USDZ file."
            case .textureMissing: "The USDZ file was written without its texture."
            }
        }
    }

    /// - Parameters:
    ///   - positions: Metres, face looking down +Z. Moved so the bounding box centre is at the origin.
    ///   - indices: Triangle list.
    ///   - uvs: One per vertex, origin at the top left of the texture (SceneKit convention).
    static func write(
        positions: [SIMD3<Float>],
        indices: [UInt32],
        uvs: [SIMD2<Float>],
        texture: CGImage,
        to url: URL
    ) throws {
        guard !positions.isEmpty, indices.count >= 3, uvs.count == positions.count else {
            throw WriteError.emptyMesh
        }

        var low = positions[0], high = positions[0]
        for position in positions {
            low = simd_min(low, position)
            high = simd_max(high, position)
        }
        let centre = (low + high) / 2
        let centred = positions.map { $0 - centre }
        let (normals, triangles) = outwardNormals(positions: centred, indices: indices)

        // SceneKit embeds a texture reliably when the material points at a file.
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Face-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textureURL = folder.appending(path: "face.png")
        guard
            let destination = CGImageDestinationCreateWithURL(
                textureURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw WriteError.textureFailed }
        CGImageDestinationAddImage(destination, texture, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.textureFailed }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: centred.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(textureCoordinates: uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }),
            ],
            elements: [SCNGeometryElement(indices: triangles, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = textureURL
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        // The photo already contains the lighting. Keep the surface matte.
        material.roughness.contents = 1.0
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "Face"
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)

        try? FileManager.default.removeItem(at: url)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw WriteError.exportFailed
        }
        guard containsPNG(at: url) else {
            try? FileManager.default.removeItem(at: url)
            throw WriteError.textureMissing
        }
    }

    /// Area weighted vertex normals. The face looks down +Z, so if the normals point
    /// the other way on average the winding is reversed.
    private static func outwardNormals(
        positions: [SIMD3<Float>], indices: [UInt32]
    ) -> (normals: [SIMD3<Float>], indices: [UInt32]) {
        var triangles = indices
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var total = SIMD3<Float>.zero
        for start in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = Int(triangles[start]), b = Int(triangles[start + 1]), c = Int(triangles[start + 2])
            let normal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += normal
            normals[b] += normal
            normals[c] += normal
            total += normal
        }
        if total.z < 0 {
            for start in stride(from: 0, to: triangles.count - 2, by: 3) {
                triangles.swapAt(start + 1, start + 2)
            }
            normals = normals.map { -$0 }
        }
        normals = normals.map { simd_length_squared($0) > 0 ? simd_normalize($0) : SIMD3(0, 0, 1) }
        return (normals, triangles)
    }

    /// USDZ is an uncompressed zip, so an embedded PNG shows up with its file signature.
    private static func containsPNG(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return data.range(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) != nil
    }
}
