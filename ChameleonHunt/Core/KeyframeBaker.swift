//
//  KeyframeBaker.swift
//  Colors the extracted LiDAR mesh by projecting the camera keyframes captured
//  while scanning back onto it.
//
//  For each triangle we shortlist the (up to) three keyframes that see it most
//  head-on and from closest. For each texel we project into those keyframes,
//  reject any whose LiDAR depth map says something was in front of the texel
//  (so the couch doesn't get painted onto the wall behind it), and blend the
//  survivors. Weights fade near image borders to hide seams between keyframes.
//
//  Camera conventions match ARKit: `cameraToWorld` is `ARCamera.transform`
//  (+X right, +Y up, looking down -Z, in the sensor's landscape orientation) and
//  the intrinsics are in the pixels of `rgba`, whose row 0 is the top of the image.
//

import Foundation
import simd

struct Keyframe: Sendable {
    let width: Int
    let height: Int
    /// RGBA8 sRGB, row 0 = top of the camera image.
    let rgba: [UInt8]
    /// fx, fy, cx, cy in pixels of `rgba`.
    let intrinsics: SIMD4<Float>
    let cameraToWorld: simd_float4x4
    let depthWidth: Int
    let depthHeight: Int
    /// Meters along the optical axis; 0 marks low-confidence / missing samples.
    let depth: [Float]

    var position: Vec3 { cameraToWorld.translation }
}

enum KeyframeBaker {

    private struct PreparedFrame: Sendable {
        let frame: Keyframe
        let anchorToCamera: simd_float4x4
        let position: Vec3   // anchor space
    }

    /// Projects an anchor-space point. Returns pixel coordinates and optical-axis depth.
    @inline(__always) static func project(_ p: Vec3, anchorToCamera: simd_float4x4,
                                          intrinsics k: SIMD4<Float>) -> (u: Float, v: Float, z: Float)? {
        let c = anchorToCamera.transformPoint(p)
        let z = -c.z
        guard z > 0.05 else { return nil }
        return (k.x * c.x / z + k.z, k.y * (-c.y) / z + k.w, z)
    }

    static func bake(_ env: inout EnvironmentGeometry, keyframes: [Keyframe],
                     worldToAnchor: simd_float4x4, progress: @Sendable (Float) -> Void) {
        guard !keyframes.isEmpty, env.triangleCount > 0 else { return }

        let prepared = keyframes.map { frame -> PreparedFrame in
            let cameraToAnchor = worldToAnchor * frame.cameraToWorld
            return PreparedFrame(frame: frame, anchorToCamera: cameraToAnchor.inverse,
                                 position: cameraToAnchor.translation)
        }

        let geometry = env
        let width = geometry.atlas.width
        let triangleCount = geometry.triangleCount
        let completed = Counter()

        env.pixels.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            Parallel.forEachChunk(count: triangleCount, minimumChunk: 256) { range in
                for tri in range {
                    bakeTriangle(tri, geometry: geometry, frames: prepared, width: width, out: out)
                }
                let done = completed.add(range.count)
                progress(Float(done) / Float(triangleCount))
            }
        }

        fillHoles(&env.pixels)
    }

    private static func bakeTriangle(_ tri: Int, geometry: EnvironmentGeometry, frames: [PreparedFrame],
                                     width: Int, out: UnsafeSendablePointer<UInt8>) {
        let a = geometry.bvh.v0[tri], b = geometry.bvh.v1[tri], c = geometry.bvh.v2[tri]
        let centroid = (a + b + c) / 3
        let normal = geometry.faceNormals[tri]

        // Shortlist the best three keyframes for this triangle.
        var best: [(index: Int, score: Float)] = []
        best.reserveCapacity(4)
        for (index, prepared) in frames.enumerated() {
            let toCamera = prepared.position - centroid
            let distance = simd_length(toCamera)
            // LiDAR mesh winding isn't reliable, so treat faces as double-sided.
            let facing = abs(simd_dot(normal, toCamera / distance))
            guard facing > 0.15,
                  let projected = project(centroid, anchorToCamera: prepared.anchorToCamera,
                                          intrinsics: prepared.frame.intrinsics),
                  inBounds(projected.u, projected.v, prepared.frame, margin: 2),
                  !isOccluded(projected, prepared.frame) else { continue }
            let score = facing * facing / max(projected.z, 0.25)
            best.append((index, score))
            best.sort { $0.score > $1.score }
            if best.count > 3 { best.removeLast() }
        }

        geometry.forEachTexel(ofTriangle: tri) { x, y, point in
            var sum = Color3.zero
            var weight: Float = 0
            for candidate in best {
                let prepared = frames[candidate.index]
                guard let projected = project(point, anchorToCamera: prepared.anchorToCamera,
                                              intrinsics: prepared.frame.intrinsics),
                      inBounds(projected.u, projected.v, prepared.frame, margin: 1),
                      !isOccluded(projected, prepared.frame) else { continue }
                let frame = prepared.frame
                let border = min(projected.u, Float(frame.width) - projected.u,
                                 projected.v, Float(frame.height) - projected.v)
                let w = candidate.score * min(max(border / 48, 0.05), 1)
                sum += sample(frame, u: projected.u, v: projected.v) * w
                weight += w
            }

            // Nothing passed the depth test: take the best keyframe anyway rather than leave a hole.
            if weight == 0, let first = best.first {
                let prepared = frames[first.index]
                if let projected = project(point, anchorToCamera: prepared.anchorToCamera,
                                           intrinsics: prepared.frame.intrinsics),
                   inBounds(projected.u, projected.v, prepared.frame, margin: 1) {
                    sum = sample(prepared.frame, u: projected.u, v: projected.v)
                    weight = 1
                }
            }

            let i = (y * width + x) * 4
            if weight > 0 {
                let (r, g, bl) = packRGBA(sum / weight)
                out.base[i] = r; out.base[i + 1] = g; out.base[i + 2] = bl; out.base[i + 3] = 255
            } else {
                out.base[i + 3] = 0   // hole, filled afterwards
            }
        }
    }

    @inline(__always) private static func inBounds(_ u: Float, _ v: Float, _ frame: Keyframe, margin: Float) -> Bool {
        u >= margin && v >= margin && u < Float(frame.width) - margin && v < Float(frame.height) - margin
    }

    @inline(__always) private static func isOccluded(_ p: (u: Float, v: Float, z: Float), _ frame: Keyframe) -> Bool {
        guard frame.depthWidth > 0 else { return false }
        let dx = min(max(Int(p.u * Float(frame.depthWidth) / Float(frame.width)), 0), frame.depthWidth - 1)
        let dy = min(max(Int(p.v * Float(frame.depthHeight) / Float(frame.height)), 0), frame.depthHeight - 1)
        let d = frame.depth[dy * frame.depthWidth + dx]
        guard d > 0 else { return false }
        return p.z > d + 0.03 + 0.03 * d
    }

    @inline(__always) private static func sample(_ frame: Keyframe, u: Float, v: Float) -> Color3 {
        frame.rgba.withUnsafeBufferPointer { buffer in
            EnvironmentGeometry.bilinear(buffer, width: frame.width, height: frame.height, x: u - 0.5, y: v - 0.5)
        }
    }

    /// Any texel no keyframe could see gets the average of everything that was seen.
    private static func fillHoles(_ pixels: inout [UInt8]) {
        var total = SIMD3<Double>.zero
        var count = 0.0
        var holes = false
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i + 3] == 0 { holes = true; continue }
            total += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
            count += 1
        }
        guard holes else { return }
        let mean = count > 0 ? total / count : SIMD3(128, 128, 128)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] == 0 {
            pixels[i] = UInt8(mean.x); pixels[i + 1] = UInt8(mean.y); pixels[i + 2] = UInt8(mean.z); pixels[i + 3] = 255
        }
    }
}

/// Thread-safe progress counter.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func add(_ n: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += n
        return value
    }
}
