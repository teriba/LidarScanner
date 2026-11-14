import ARKit

enum MeshExportError: LocalizedError {
    case noMesh

    var errorDescription: String? {
        "No mesh captured yet. Move the phone around a bit more."
    }
}

enum MeshExporter {
    /// Writes ARKit mesh anchors to one OBJ in world space. Faces are grouped by their
    /// ARKit class (wall, floor, ...) when the session provides classification.
    static func export(_ anchors: [ARMeshAnchor], to url: URL) throws {
        guard !anchors.isEmpty else { throw MeshExportError.noMesh }
        var mesh = TriMesh()
        for anchor in anchors { append(anchor, to: &mesh) }
        guard mesh.triangleCount > 0 else { throw MeshExportError.noMesh }
        try OBJFile.write(mesh, to: url)
    }

    private static func append(_ anchor: ARMeshAnchor, to mesh: inout TriMesh) {
        let geometry = anchor.geometry
        let baseVertex = UInt32(mesh.positions.count)

        // Vertices and normals are packed float3 in anchor space. Bake the anchor
        // transform in so every chunk lands in a shared world space.
        let vertices = geometry.vertices
        let normals = geometry.normals
        let hasNormals = normals.count == vertices.count
        let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
        let normalBase = normals.buffer.contents().advanced(by: normals.offset)
        for index in 0..<vertices.count {
            let v = vertexBase.advanced(by: index * vertices.stride)
                .assumingMemoryBound(to: (Float, Float, Float).self).pointee
            let world = anchor.transform * SIMD4<Float>(v.0, v.1, v.2, 1)
            mesh.positions.append(SIMD3(world.x, world.y, world.z))
            var normal = SIMD3<Float>(0, 1, 0)
            if hasNormals {
                let n = normalBase.advanced(by: index * normals.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let rotated = anchor.transform * SIMD4<Float>(n.0, n.1, n.2, 0)
                normal = SIMD3(rotated.x, rotated.y, rotated.z)
            }
            mesh.normals.append(normal)
        }

        let faces = geometry.faces
        guard faces.primitiveType == .triangle else { return }
        let indexBase = faces.buffer.contents()
        let classification = geometry.classification
        for face in 0..<faces.count {
            for corner in 0..<3 {
                let pointer = indexBase.advanced(by: (face * 3 + corner) * faces.bytesPerIndex)
                let index = faces.bytesPerIndex == 2
                    ? UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
                    : pointer.assumingMemoryBound(to: UInt32.self).pointee
                mesh.indices.append(baseVertex + index)
            }
            // One byte per face. Its values match MeshClass.
            var faceClass: UInt8 = 0
            if let classification, face < classification.count {
                faceClass = classification.buffer.contents()
                    .advanced(by: classification.offset + face * classification.stride)
                    .assumingMemoryBound(to: UInt8.self).pointee
            }
            mesh.classes.append(faceClass < MeshClass.furniture.rawValue ? faceClass : 0)
        }
    }
}
