import ARKit
import CoreImage
import simd

/// One face capture: geometry averaged over a short burst, plus the frame used for the texture.
struct FaceCapture {
    /// Face anchor space, metres. +Z points out of the face, +Y up.
    let vertices: [SIMD3<Float>]
    let indices: [Int16]
    /// Face anchor transform that belongs to `frame`.
    let transform: simd_float4x4
    let frame: ARFrame

    enum CaptureError: LocalizedError {
        case noFace
        case outsideImage
        case imageFailed

        var errorDescription: String? {
            switch self {
            case .noFace: "No face found. Try again."
            case .outsideImage: "The face is outside the camera image. Try again."
            case .imageFailed: "Could not read the camera image."
            }
        }
    }

    /// Projects every vertex into the camera image, uses the result as UVs, and writes
    /// the mesh with the cropped camera image as its texture.
    func write(to url: URL) throws {
        guard !vertices.isEmpty else { throw CaptureError.noFace }
        let pixels = imagePixels()

        var low = pixels[0], high = pixels[0]
        for pixel in pixels {
            low = simd_min(low, pixel)
            high = simd_max(high, pixel)
        }
        let buffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let padding = 0.04 * Double(simd_reduce_max(high - low))
        let crop = CGRect(
            x: Double(low.x) - padding, y: Double(low.y) - padding,
            width: Double(high.x - low.x) + 2 * padding, height: Double(high.y - low.y) + 2 * padding
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard crop.width >= 16, crop.height >= 16 else { throw CaptureError.outsideImage }

        // Core Image has its origin at the bottom left, the pixel coordinates at the top left.
        let source = CGRect(x: crop.minX, y: CGFloat(height) - crop.maxY, width: crop.width, height: crop.height)
        guard let texture = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: source) else {
            throw CaptureError.imageFailed
        }

        let origin = SIMD2(Float(crop.minX), Float(crop.minY))
        let size = SIMD2(Float(crop.width), Float(crop.height))
        // Vertices outside the image keep the nearest edge colour.
        let uvs = pixels.map { simd_clamp(($0 - origin) / size, SIMD2(repeating: 0), SIMD2(repeating: 1)) }

        try FaceModelWriter.write(
            positions: vertices,
            indices: indices.map { UInt32($0) },
            uvs: uvs,
            texture: texture,
            to: url
        )
    }

    /// Position of each vertex in `frame.capturedImage`, in pixels from the top left.
    private func imagePixels() -> [SIMD2<Float>] {
        let camera = frame.camera
        // capturedImage is in sensor orientation, which is landscape right. A viewport of
        // the same size and orientation has no rotation or crop.
        let size = camera.imageResolution
        // The view shows the front camera mirrored and ARKit projects to match the view.
        // displayTransform maps image to view, so its inverse takes the projection back
        // to the unmirrored camera image.
        let viewToImage = frame.displayTransform(for: .landscapeRight, viewportSize: size).inverted()
        return vertices.map { vertex in
            let world = transform * SIMD4(vertex, 1)
            let point = camera.projectPoint(
                SIMD3(world.x, world.y, world.z), orientation: .landscapeRight, viewportSize: size)
            let image = CGPoint(x: point.x / size.width, y: point.y / size.height).applying(viewToImage)
            return SIMD2(Float(image.x * size.width), Float(image.y * size.height))
        }
    }
}
