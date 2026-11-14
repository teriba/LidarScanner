import Foundation
import simd

enum OBJFileError: LocalizedError {
    case empty

    var errorDescription: String? {
        "The file has no triangles."
    }
}

/// Minimal OBJ reader and writer for TriMesh. Face classes are stored as groups
/// named after MeshClass, e.g. "g wall".
enum OBJFile {
    // MARK: Write

    /// Streams the mesh to disk in 1 MB pieces.
    static func write(_ mesh: TriMesh, to url: URL, progress: (Double) -> Void = { _ in }) throws {
        guard mesh.triangleCount > 0 else { throw OBJFileError.empty }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer: [UInt8] = []
        buffer.reserveCapacity(1 << 20)
        func flushIfFull(force: Bool = false) throws {
            if buffer.count >= (1 << 20) - 256 || force {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        let hasNormals = mesh.normals.count == mesh.positions.count
        let total = Double(mesh.positions.count * (hasNormals ? 2 : 1) + mesh.triangleCount)
        var done = 0
        func step() {
            done += 1
            if done & 0xFFFF == 0 { progress(Double(done) / total) }
        }

        buffer.append(contentsOf: "# LiDAR Scanner mesh, metres, Y up\n".utf8)
        for p in mesh.positions {
            buffer.append(contentsOf: [UInt8(ascii: "v"), UInt8(ascii: " ")])
            appendVector(p, decimals: 4, to: &buffer)
            try flushIfFull()
            step()
        }
        if hasNormals {
            for n in mesh.normals {
                buffer.append(contentsOf: [UInt8(ascii: "v"), UInt8(ascii: "n"), UInt8(ascii: " ")])
                appendVector(n, decimals: 3, to: &buffer)
                try flushIfFull()
                step()
            }
        }

        let hasClasses = mesh.classes.count == mesh.triangleCount
        var present = [Bool](repeating: false, count: 256)
        if hasClasses {
            for value in mesh.classes { present[Int(value)] = true }
        } else {
            present[0] = true
        }
        for value in 0..<256 where present[value] {
            let name = hasClasses ? (MeshClass(rawValue: UInt8(value)) ?? .none).name : "mesh"
            buffer.append(contentsOf: "g \(name)\n".utf8)
            for t in 0..<mesh.triangleCount where !hasClasses || mesh.classes[t] == UInt8(value) {
                buffer.append(UInt8(ascii: "f"))
                for corner in 0..<3 {
                    let index = Int(mesh.indices[t * 3 + corner]) + 1
                    buffer.append(UInt8(ascii: " "))
                    appendInteger(index, to: &buffer)
                    if hasNormals {
                        buffer.append(contentsOf: [UInt8(ascii: "/"), UInt8(ascii: "/")])
                        appendInteger(index, to: &buffer)
                    }
                }
                buffer.append(UInt8(ascii: "\n"))
                try flushIfFull()
                step()
            }
        }
        try flushIfFull(force: true)
        progress(1)
    }

    private static func appendVector(_ v: SIMD3<Float>, decimals: Int, to buffer: inout [UInt8]) {
        appendFixed(v.x, decimals: decimals, to: &buffer)
        buffer.append(UInt8(ascii: " "))
        appendFixed(v.y, decimals: decimals, to: &buffer)
        buffer.append(UInt8(ascii: " "))
        appendFixed(v.z, decimals: decimals, to: &buffer)
        buffer.append(UInt8(ascii: "\n"))
    }

    private static func appendInteger(_ value: Int, to buffer: inout [UInt8]) {
        var digits: [UInt8] = []
        var rest = value
        repeat {
            digits.append(UInt8(ascii: "0") + UInt8(rest % 10))
            rest /= 10
        } while rest > 0
        buffer.append(contentsOf: digits.reversed())
    }

    /// Fixed-point text without going through String, which is slow for millions of numbers.
    private static func appendFixed(_ value: Float, decimals: Int, to buffer: inout [UInt8]) {
        var scale = 1.0
        for _ in 0..<decimals { scale *= 10 }
        let clamped = value.isFinite ? min(max(Double(value), -1e9), 1e9) : 0
        let scaled = Int((abs(clamped) * scale).rounded())
        if clamped < 0, scaled != 0 { buffer.append(UInt8(ascii: "-")) }
        appendInteger(scaled / Int(scale), to: &buffer)
        buffer.append(UInt8(ascii: "."))
        var fraction = scaled % Int(scale)
        var divisor = Int(scale) / 10
        while divisor > 0 {
            buffer.append(UInt8(ascii: "0") + UInt8(fraction / divisor))
            fraction %= divisor
            divisor /= 10
        }
    }

    // MARK: Read

    /// Reads positions and faces. Polygons are split into triangle fans. Classes are filled
    /// in only when the file has groups named after MeshClass.
    static func read(_ url: URL, progress: (Double) -> Void = { _ in }) throws -> TriMesh {
        // Memory mapped, so a large file is paged in by the system instead of copied.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var mesh = TriMesh()
        var currentClass: UInt8 = 0
        var sawClass = false

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 0
            var lines = 0
            var corners: [Int] = []

            func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
            func isLineEnd(_ byte: UInt8) -> Bool { byte == 0x0A || byte == 0x0D }
            func skipSpaces() {
                while i < count, isSpace(bytes[i]) { i += 1 }
            }
            func parseInteger() -> Int? {
                var negative = false
                if i < count, bytes[i] == UInt8(ascii: "-") {
                    negative = true
                    i += 1
                }
                var value = 0
                var digits = 0
                while i < count, bytes[i] >= 0x30, bytes[i] <= 0x39, digits < 18 {
                    value = value * 10 + Int(bytes[i] - 0x30)
                    digits += 1
                    i += 1
                }
                return digits > 0 ? (negative ? -value : value) : nil
            }
            func parseFloat() -> Float {
                skipSpaces()
                var negative = false
                if i < count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
                    negative = bytes[i] == UInt8(ascii: "-")
                    i += 1
                }
                var value = 0.0
                while i < count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                    value = value * 10 + Double(bytes[i] - 0x30)
                    i += 1
                }
                if i < count, bytes[i] == UInt8(ascii: ".") {
                    i += 1
                    var scale = 0.1
                    while i < count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                        value += Double(bytes[i] - 0x30) * scale
                        scale *= 0.1
                        i += 1
                    }
                }
                if i < count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                    i += 1
                    var sign = 1
                    if i < count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
                        sign = bytes[i] == UInt8(ascii: "-") ? -1 : 1
                        i += 1
                    }
                    let exponent = parseInteger() ?? 0
                    value *= pow(10, Double(sign * min(exponent, 300)))
                }
                return Float(negative ? -value : value)
            }

            while i < count {
                skipSpaces()
                let hasArgument = i + 1 < count && isSpace(bytes[i + 1])
                if i < count, hasArgument, bytes[i] == UInt8(ascii: "v") {
                    i += 1
                    mesh.positions.append(SIMD3(parseFloat(), parseFloat(), parseFloat()))
                } else if i < count, hasArgument, bytes[i] == UInt8(ascii: "f") {
                    i += 1
                    corners.removeAll(keepingCapacity: true)
                    while true {
                        skipSpaces()
                        guard let index = parseInteger() else { break }
                        // Negative indices count back from the last vertex read so far.
                        corners.append(index > 0 ? index - 1 : mesh.positions.count + index)
                        // Skip texture and normal references.
                        while i < count, !isSpace(bytes[i]), !isLineEnd(bytes[i]) { i += 1 }
                    }
                    if corners.count >= 3 {
                        for k in 1..<(corners.count - 1) {
                            let triangle = [corners[0], corners[k], corners[k + 1]]
                            if triangle.allSatisfy({ $0 >= 0 && $0 < Int(UInt32.max) }) {
                                mesh.indices.append(contentsOf: triangle.map { UInt32($0) })
                                mesh.classes.append(currentClass)
                            }
                        }
                    }
                } else if i < count, hasArgument, bytes[i] == UInt8(ascii: "g") {
                    i += 1
                    skipSpaces()
                    let start = i
                    while i < count, !isSpace(bytes[i]), !isLineEnd(bytes[i]) { i += 1 }
                    let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                    if let match = MeshClass(name: name.lowercased()) {
                        currentClass = match.rawValue
                        sawClass = true
                    } else {
                        currentClass = 0
                    }
                }
                while i < count, bytes[i] != 0x0A { i += 1 }
                i += 1
                lines += 1
                if lines & 0xFFFF == 0 { progress(Double(i) / Double(count)) }
            }
        }

        // Faces may come before the vertices they use, so validate at the end.
        let vertexCount = UInt32(mesh.positions.count)
        if mesh.indices.contains(where: { $0 >= vertexCount }) {
            let keep = (0..<mesh.triangleCount).map { t in
                mesh.indices[t * 3] < vertexCount && mesh.indices[t * 3 + 1] < vertexCount
                    && mesh.indices[t * 3 + 2] < vertexCount
            }
            var indices: [UInt32] = []
            var classes: [UInt8] = []
            for t in 0..<mesh.triangleCount where keep[t] {
                indices.append(contentsOf: mesh.indices[(t * 3)..<(t * 3 + 3)])
                classes.append(mesh.classes[t])
            }
            mesh.indices = indices
            mesh.classes = classes
        }
        if !sawClass { mesh.classes = [] }
        guard mesh.triangleCount > 0 else { throw OBJFileError.empty }
        progress(1)
        return mesh
    }
}
