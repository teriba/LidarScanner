import ARKit
import ModelIO

enum MeshExportError: LocalizedError {
    case noMesh

    var errorDescription: String? {
        "No mesh captured yet. Move the phone around a bit more."
    }
}

enum MeshExporter {
    /// Writes ARKit mesh anchors to a file (format from the URL extension, e.g. .obj).
    static func export(_ anchors: [ARMeshAnchor], to url: URL) throws {
        guard !anchors.isEmpty else { throw MeshExportError.noMesh }
        let allocator = MDLMeshBufferDataAllocator()
        let asset = MDLAsset(bufferAllocator: allocator)
        for anchor in anchors {
            asset.add(mesh(for: anchor, allocator: allocator))
        }
        try asset.export(to: url)
    }

    private static func mesh(for anchor: ARMeshAnchor, allocator: MDLMeshBufferAllocator) -> MDLMesh {
        let geometry = anchor.geometry

        // Vertices are packed float3 in anchor space. Bake the anchor transform in so
        // every chunk lands in a shared world space.
        let source = geometry.vertices
        let base = source.buffer.contents().advanced(by: source.offset)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(source.count)
        for index in 0..<source.count {
            let v = base.advanced(by: index * source.stride)
                .assumingMemoryBound(to: (Float, Float, Float).self).pointee
            let world = anchor.transform * SIMD4<Float>(v.0, v.1, v.2, 1)
            positions.append(SIMD3(world.x, world.y, world.z))
        }

        let faces = geometry.faces
        let indexCount = faces.count * faces.indexCountPerPrimitive
        let indexData = Data(bytes: faces.buffer.contents(), count: indexCount * faces.bytesPerIndex)
        let indexType: MDLIndexBitDepth = faces.bytesPerIndex == 2 ? .uInt16 : .uInt32

        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        let submesh = MDLSubmesh(
            indexBuffer: allocator.newBuffer(with: indexData, type: .index),
            indexCount: indexCount,
            indexType: indexType,
            geometryType: .triangles,
            material: nil
        )
        let mesh = MDLMesh(
            vertexBuffer: allocator.newBuffer(with: vertexData, type: .vertex),
            vertexCount: positions.count,
            descriptor: descriptor,
            submeshes: [submesh]
        )
        mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        return mesh
    }
}
