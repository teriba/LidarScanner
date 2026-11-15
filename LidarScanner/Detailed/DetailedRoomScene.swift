import CoreGraphics
import Foundation
import ImageIO
import SceneKit
import UniformTypeIdentifiers
import simd

/// Builds the SceneKit scene of a detailed room from its sidecar folder, and writes it
/// as USDZ. SceneKit and ImageIO only, so it also compiles on macOS for testing.
enum DetailedRoomScene {
    enum SceneError: LocalizedError {
        case textureFailed
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .textureFailed: "Could not save a texture."
            case .exportFailed: "Could not write the USDZ file."
            }
        }
    }

    static let highlightName = "selection"

    /// Finds the USDZ of a replacement. The editor passes its own to show object scans
    /// that are not copied into the sidecar yet.
    typealias ReplacementSource = (String) -> URL

    /// Room structure plus one node per item, named with the item id.
    static func make(
        package: DetailedRoomPackage, manifest: DetailedRoomManifest, source: ReplacementSource? = nil
    ) -> SCNScene {
        let scene = (try? SCNScene(url: package.structureURL)) ?? SCNScene()
        for item in manifest.items {
            let node = SCNNode()
            node.name = item.id
            update(node, item: item, package: package, source: source)
            scene.rootNode.addChildNode(node)
        }
        if manifest.hasLooseDetail, manifest.showLooseDetail, let node = looseDetailNode(package: package) {
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    static func looseDetailNode(package: DetailedRoomPackage) -> SCNNode? {
        let node = meshNode(DetailedRoomPackage.looseDetailName, package: package)
        node?.name = DetailedRoomPackage.looseDetailName
        return node
    }

    /// Rebuilds the content of an item node after its display or placement changed.
    static func update(
        _ node: SCNNode, item: DetailedRoomManifest.Item, package: DetailedRoomPackage, source: ReplacementSource? = nil
    ) {
        for child in node.childNodes where child.name != highlightName {
            child.removeFromParentNode()
        }
        var content: SCNNode?
        switch item.display {
        case .mesh:
            if item.hasMesh { content = meshNode(item.id, package: package) }
        case .replacement:
            if let replacement = item.replacement {
                let url = source?(replacement.file) ?? package.replacementURL(replacement.file)
                content = replacementNode(replacement, pose: item.pose, url: url)
            }
        case .box:
            break
        }
        node.addChildNode(content ?? boxNode(item))
    }

    static func setHighlight(_ on: Bool, node: SCNNode, item: DetailedRoomManifest.Item) {
        node.childNode(withName: highlightName, recursively: false)?.removeFromParentNode()
        guard on else { return }
        let size = item.pose.dimensions + SIMD3(repeating: 0.04)
        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = CGColor(red: 1, green: 0.8, blue: 0, alpha: 0.3)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        box.materials = [material]
        let highlight = SCNNode(geometry: box)
        highlight.name = highlightName
        highlight.simdTransform = item.pose.transform
        node.addChildNode(highlight)
    }

    /// Writes the room as USDZ. `output` appears only when the export succeeds.
    static func export(package: DetailedRoomPackage, manifest: DetailedRoomManifest, to output: URL) throws {
        let scene = make(package: package, manifest: manifest)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Detailed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appending(path: "room.usdz")
        guard scene.write(to: temporary, options: nil, delegate: nil, progressHandler: nil) else {
            throw SceneError.exportFailed
        }
        try FileManager.default.moveItem(at: temporary, to: output)
    }

    // MARK: Nodes

    private static func boxNode(_ item: DetailedRoomManifest.Item) -> SCNNode {
        let size = item.pose.dimensions
        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        let color = item.color.flatMap { $0.count == 3 ? $0 : nil } ?? [0.7, 0.7, 0.7]
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = CGColor(
            srgbRed: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]), alpha: 1
        )
        material.roughness.contents = 0.9
        material.metalness.contents = 0.0
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.simdTransform = item.pose.transform
        return node
    }

    private static func meshNode(_ name: String, package: DetailedRoomPackage) -> SCNNode? {
        guard let mesh = try? PaletteMesh(contentsOf: package.meshURL(name)), mesh.triangleCount > 0 else { return nil }
        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(textureCoordinates: mesh.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }),
            ],
            elements: [SCNGeometryElement(indices: (0..<UInt32(mesh.positions.count)).map { $0 }, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        // SceneKit embeds a texture reliably when the material points at a file.
        material.diffuse.contents = package.textureURL(name)
        material.diffuse.magnificationFilter = .nearest
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        // The camera colours already contain the lighting. Keep the surface matte.
        material.roughness.contents = 1.0
        material.metalness.contents = 0.0
        // Scan meshes are open shells.
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func replacementNode(
        _ replacement: DetailedRoomManifest.Replacement, pose: BoxPose, url: URL
    ) -> SCNNode? {
        guard let scene = try? SCNScene(url: url) else { return nil }
        let model = SCNNode()
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            model.addChildNode(child)
        }
        // A node's bounding box covers its children, in the node's own space.
        let (low, high) = model.boundingBox
        let modelMin = SIMD3<Float>(Float(low.x), Float(low.y), Float(low.z))
        let modelMax = SIMD3<Float>(Float(high.x), Float(high.y), Float(high.z))
        guard simd_reduce_max(modelMax - modelMin) > 0 else { return nil }
        model.simdTransform = ObjectPlacement.transform(
            box: pose,
            modelMin: modelMin,
            modelMax: modelMax,
            fitToBox: replacement.fitToBox,
            quarterTurns: replacement.quarterTurns,
            nudge: replacement.nudgeVector
        )
        return model
    }

    // MARK: Texture

    /// Saves a palette texture as PNG.
    static func writeTexture(_ mesh: PaletteMesh, to url: URL) throws {
        guard mesh.textureWidth > 0, mesh.textureHeight > 0,
              let provider = CGDataProvider(data: Data(mesh.texture) as CFData),
              let image = CGImage(
                  width: mesh.textureWidth,
                  height: mesh.textureHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: mesh.textureWidth * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SceneError.textureFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SceneError.textureFailed }
    }
}
