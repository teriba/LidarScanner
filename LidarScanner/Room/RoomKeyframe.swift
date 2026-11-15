import Foundation
import simd

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

/// Projects world points into keyframes and reads their colour. Foundation and simd only.
enum KeyframeSampler {
    static let depthRange: ClosedRange<Float> = 0.3...6
    /// A point this far behind the measured depth counts as hidden.
    static let occlusionTolerance: Float = 0.12

    /// Pixel position and depth of a world point in a keyframe. Nil when it is out of
    /// range or outside the image. The camera looks down -Z with +Y up, image rows grow downwards.
    static func project(_ point: SIMD3<Float>, into keyframe: RoomKeyframe) -> (x: Float, y: Float, depth: Float)? {
        let camera = keyframe.worldToCamera * SIMD4<Float>(point, 1)
        let depth = -camera.z
        guard depthRange.contains(depth) else { return nil }
        let x = keyframe.focal.x * camera.x / depth + keyframe.center.x
        let y = -keyframe.focal.y * camera.y / depth + keyframe.center.y
        guard x >= 1, y >= 1, x < Float(RoomKeyframe.width - 1), y < Float(RoomKeyframe.height - 1) else { return nil }
        return (x, y, depth)
    }

    /// Weighted mean (linear RGB) of the point over all keyframes that see it. Closer views
    /// weigh more. With a normal, only keyframes in front of the surface count.
    static func color(at position: SIMD3<Float>, normal: SIMD3<Float>?, keyframes: [RoomKeyframe]) -> SIMD3<Float>? {
        var sum = SIMD3<Float>()
        var totalWeight: Float = 0
        for keyframe in keyframes {
            guard let (x, y, depth) = project(position, into: keyframe) else { continue }
            if let normal {
                let toCamera = simd_normalize(keyframe.position - position)
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

    static func sRGBToLinear(_ byte: UInt8) -> Float {
        let value = Float(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    static func linearToSRGB(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(linearToSRGB(color.x), linearToSRGB(color.y), linearToSRGB(color.z))
    }
}

extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
