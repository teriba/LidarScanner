import ARKit
import CoreImage
import RoomPlan
import SceneKit

/// A downscaled camera frame with the pose it was taken from.
struct RoomKeyframe: Sendable {
    static let width = 256
    static let height = 192

    /// RGBA8, sRGB, `width * height * 4` bytes.
    let pixels: [UInt8]
    /// Depth in metres along the camera axis, row-major. Empty if the frame had no depth.
    let depth: [Float]
    let depthWidth: Int
    let depthHeight: Int
    /// Intrinsics scaled to the downscaled image.
    let focal: SIMD2<Float>
    let center: SIMD2<Float>
    let cameraTransform: simd_float4x4
    let worldToCamera: simd_float4x4

    var position: SIMD3<Float> { cameraTransform.columns.3.xyz }
}

/// Polls the RoomPlan ARSession for keyframes while scanning. It polls instead of taking
/// the session delegate, which RoomPlan may be using itself. Use from the main thread only.
final class RoomKeyframeRecorder {
    private(set) var keyframes: [RoomKeyframe] = []

    private static let maxKeyframes = 80
    private static let pollInterval: TimeInterval = 0.25
    /// A new keyframe needs this much movement since the last one.
    private static let minDistance: Float = 0.25
    private static let minAngleCosine: Float = cos(12 * .pi / 180)

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var timer: Timer?
    private weak var session: ARSession?

    func start(session: ARSession) {
        stop()
        keyframes = []
        self.session = session
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, let frame = self.session?.currentFrame else { return }
            self.consider(frame)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func consider(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        let transform = frame.camera.transform
        if let last = keyframes.last {
            let moved = simd_distance(last.position, transform.columns.3.xyz)
            let turned = simd_dot(last.cameraTransform.columns.2.xyz, transform.columns.2.xyz)
            guard moved > Self.minDistance || turned < Self.minAngleCosine else { return }
        }
        guard let keyframe = makeKeyframe(from: frame) else { return }
        keyframes.append(keyframe)
        if keyframes.count > Self.maxKeyframes {
            // Drop every other frame. Coverage stays even and memory stays bounded.
            keyframes = keyframes.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        }
    }

    private func makeKeyframe(from frame: ARFrame) -> RoomKeyframe? {
        let width = RoomKeyframe.width
        let height = RoomKeyframe.height
        let resolution = frame.camera.imageResolution
        guard resolution.width > 0, resolution.height > 0 else { return nil }
        let scaleX = CGFloat(width) / resolution.width
        let scaleY = CGFloat(height) / resolution.height

        let image = CIImage(cvPixelBuffer: frame.capturedImage)
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ])
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        let depth = (frame.smoothedSceneDepth ?? frame.sceneDepth).flatMap { Self.copyDepth($0.depthMap) }
        let intrinsics = frame.camera.intrinsics
        return RoomKeyframe(
            pixels: pixels,
            depth: depth?.values ?? [],
            depthWidth: depth?.width ?? 0,
            depthHeight: depth?.height ?? 0,
            focal: SIMD2(intrinsics[0][0] * Float(scaleX), intrinsics[1][1] * Float(scaleY)),
            center: SIMD2(intrinsics[2][0] * Float(scaleX), intrinsics[2][1] * Float(scaleY)),
            cameraTransform: frame.camera.transform,
            worldToCamera: frame.camera.transform.inverse
        )
    }

    /// Copies the Float32 depth map at half resolution.
    private static func copyDepth(_ buffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer) / 2
        let height = CVPixelBufferGetHeight(buffer) / 2
        guard width > 0, height > 0 else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * 2 * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                values[y * width + x] = row[x * 2]
            }
        }
        return (values, width, height)
    }
}

/// Colours a RoomPlan USDZ. Each surface and object gets one flat colour, sampled from
/// the camera keyframes that saw it.
enum RoomColorizer {
    /// A point on a room element. `normal` is set for object faces, which are only
    /// visible from outside. Walls and floors can be seen from either side.
    struct SamplePoint: Sendable {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>?
    }

    /// One wall, door, window, opening, floor or object, in world space.
    struct Element: Sendable {
        let center: SIMD3<Float>
        let diagonal: Float
        let points: [SamplePoint]
    }

    private static let grid = 5
    private static let depthRange: ClosedRange<Float> = 0.3...6
    /// A point this far behind the measured depth counts as hidden.
    private static let occlusionTolerance: Float = 0.12
    /// Largest centre plus size mismatch (metres) for pairing a USDZ node with an element.
    private static let matchTolerance: Float = 0.5

    static func elements(of room: CapturedRoom) -> [Element] {
        let surfaces = room.walls + room.doors + room.windows + room.openings + room.floors
        return surfaces.map { surfaceElement(transform: $0.transform, dimensions: $0.dimensions) }
            + room.objects.map { boxElement(transform: $0.transform, dimensions: $0.dimensions) }
    }

    /// Rewrites the USDZ at `url` with one material colour per element.
    /// Returns how many nodes were coloured. The file is left alone if that is zero.
    @discardableResult
    static func colorize(usdzAt url: URL, elements: [Element], keyframes: [RoomKeyframe]) throws -> Int {
        guard !elements.isEmpty, !keyframes.isEmpty else { return 0 }
        let colors = elements.map { color(of: $0, keyframes: keyframes) }

        let scene = try SCNScene(url: url)
        var nodes: [(node: SCNNode, center: SIMD3<Float>, diagonal: Float)] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (low, high) = node.boundingBox
            let worldLow = node.simdConvertPosition(SIMD3(low), to: nil)
            let worldHigh = node.simdConvertPosition(SIMD3(high), to: nil)
            nodes.append((node, (worldLow + worldHigh) / 2, simd_distance(worldLow, worldHigh)))
        }

        // Pair nodes with elements by position and size, best pairs first.
        var pairs: [(score: Float, node: Int, element: Int)] = []
        for (nodeIndex, node) in nodes.enumerated() {
            for (elementIndex, element) in elements.enumerated() where colors[elementIndex] != nil {
                let score = simd_distance(node.center, element.center) + abs(node.diagonal - element.diagonal)
                if score < matchTolerance {
                    pairs.append((score, nodeIndex, elementIndex))
                }
            }
        }
        pairs.sort { $0.score < $1.score }

        var usedNodes = Set<Int>()
        var usedElements = Set<Int>()
        for pair in pairs where !usedNodes.contains(pair.node) && !usedElements.contains(pair.element) {
            let node = nodes[pair.node].node
            guard let color = colors[pair.element],
                  let geometry = node.geometry?.copy() as? SCNGeometry else { continue }
            usedNodes.insert(pair.node)
            usedElements.insert(pair.element)
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(
                red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1
            )
            material.roughness.contents = 0.9
            material.metalness.contents = 0.0
            // Geometry and materials can be shared between nodes, so each node gets its own.
            geometry.materials = [material]
            node.geometry = geometry
        }
        guard !usedNodes.isEmpty else { return 0 }

        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appending(path: url.lastPathComponent)
        guard scene.write(to: temporary, options: nil, delegate: nil, progressHandler: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return usedNodes.count
    }

    // MARK: Sample points

    /// Surfaces are flat rectangles in their local XY plane.
    private static func surfaceElement(transform: simd_float4x4, dimensions: SIMD3<Float>) -> Element {
        var points: [SamplePoint] = []
        for (u, v) in gridOffsets {
            let local = SIMD4<Float>(u * dimensions.x, v * dimensions.y, 0, 1)
            points.append(SamplePoint(position: (transform * local).xyz, normal: nil))
        }
        return Element(center: transform.columns.3.xyz, diagonal: simd_length(dimensions), points: points)
    }

    /// Objects are boxes. Sample every face, the unseen ones just get no colour.
    private static func boxElement(transform: simd_float4x4, dimensions: SIMD3<Float>) -> Element {
        var points: [SamplePoint] = []
        for axis in 0..<3 {
            let (a, b) = ((axis + 1) % 3, (axis + 2) % 3)
            for side: Float in [-1, 1] {
                var axisVector = SIMD4<Float>(0, 0, 0, 0)
                axisVector[axis] = side
                let normal = simd_normalize((transform * axisVector).xyz)
                for (u, v) in gridOffsets {
                    var local = SIMD4<Float>(0, 0, 0, 1)
                    local[axis] = side * dimensions[axis] / 2
                    local[a] = u * dimensions[a]
                    local[b] = v * dimensions[b]
                    points.append(SamplePoint(position: (transform * local).xyz, normal: normal))
                }
            }
        }
        return Element(center: transform.columns.3.xyz, diagonal: simd_length(dimensions), points: points)
    }

    /// Grid positions as fractions of the size, from -0.4 to 0.4. Edges are left out.
    private static let gridOffsets: [(Float, Float)] = {
        let steps = (0..<grid).map { Float($0) / Float(grid - 1) * 0.8 - 0.4 }
        return steps.flatMap { u in steps.map { v in (u, v) } }
    }()

    // MARK: Colour sampling

    /// Median colour (sRGB, 0...1) of the points any keyframe saw. The median keeps
    /// posters, doors and furniture in front of a wall from tinting the whole wall.
    private static func color(of element: Element, keyframes: [RoomKeyframe]) -> SIMD3<Float>? {
        let seen = element.points.compactMap { color(at: $0, keyframes: keyframes) }
        guard !seen.isEmpty else { return nil }
        var median = SIMD3<Float>()
        for channel in 0..<3 {
            median[channel] = seen.map { $0[channel] }.sorted()[seen.count / 2]
        }
        return SIMD3(linearToSRGB(median.x), linearToSRGB(median.y), linearToSRGB(median.z))
    }

    /// Weighted mean (linear RGB) of the point over all keyframes that see it. Closer views weigh more.
    private static func color(at point: SamplePoint, keyframes: [RoomKeyframe]) -> SIMD3<Float>? {
        var sum = SIMD3<Float>()
        var totalWeight: Float = 0
        for keyframe in keyframes {
            let camera = keyframe.worldToCamera * SIMD4<Float>(point.position, 1)
            // The camera looks down -Z with +Y up. Image rows grow downwards.
            let depth = -camera.z
            guard depthRange.contains(depth) else { continue }
            let x = keyframe.focal.x * camera.x / depth + keyframe.center.x
            let y = -keyframe.focal.y * camera.y / depth + keyframe.center.y
            guard x >= 1, y >= 1, x < Float(RoomKeyframe.width - 1), y < Float(RoomKeyframe.height - 1) else { continue }

            if let normal = point.normal {
                let toCamera = simd_normalize(keyframe.position - point.position)
                guard simd_dot(normal, toCamera) > 0.2 else { continue }
            }
            if !keyframe.depth.isEmpty {
                let dx = min(Int(x) * keyframe.depthWidth / RoomKeyframe.width, keyframe.depthWidth - 1)
                let dy = min(Int(y) * keyframe.depthHeight / RoomKeyframe.height, keyframe.depthHeight - 1)
                let measured = keyframe.depth[dy * keyframe.depthWidth + dx]
                if measured.isFinite, measured > 0, measured < depth - occlusionTolerance { continue }
            }

            let offset = (Int(y) * RoomKeyframe.width + Int(x)) * 4
            let weight = 1 / depth
            sum += weight * SIMD3(
                sRGBToLinear(keyframe.pixels[offset]),
                sRGBToLinear(keyframe.pixels[offset + 1]),
                sRGBToLinear(keyframe.pixels[offset + 2])
            )
            totalWeight += weight
        }
        return totalWeight > 0 ? sum / totalWeight : nil
    }

    private static func sRGBToLinear(_ byte: UInt8) -> Float {
        let value = Float(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
