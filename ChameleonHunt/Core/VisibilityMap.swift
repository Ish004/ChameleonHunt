//
//  VisibilityMap.swift
//  Which parts of the character the painter can actually see from where they're
//  looking — so a stroke on an arm doesn't bleed onto the chest behind it.
//
//  The brush used to answer that with a ray cast per texel, which is fine for a
//  small brush and far too slow for a big one (a 6 cm brush covers tens of thousands
//  of texels, several times a frame). Instead this renders the character's depth
//  from the painter's viewpoint once per stroke; each texel is then a projection and
//  one comparison.
//
//  Everything is in character space.
//

import Foundation
import simd

struct VisibilityMap: Sendable {

    let size: Int
    let eye: Vec3
    private let right: Vec3
    private let up: Vec3
    private let forward: Vec3
    private let tanHalf: Float
    /// Nearest surface distance along `forward` per pixel; .greatestFiniteMagnitude where empty.
    private var depth: [Float]

    /// Rasterizes the character as seen from `eye`, looking at the middle of its bounds.
    static func build(geometry: CharacterGeometry, eye: Vec3, size: Int = 256) -> VisibilityMap {
        let center = (geometry.boundsMin + geometry.boundsMax) * 0.5
        let radius = max(simd_length(geometry.boundsMax - geometry.boundsMin) * 0.5, 0.05)
        let toCenter = center - eye
        let distance = max(simd_length(toCenter), radius * 1.5)
        let forward = simd_length(toCenter) > 1e-5 ? toCenter / simd_length(toCenter) : Vec3(0, 0, -1)
        let right = simd_normalize(simd_cross(forward, abs(forward.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)))
        let up = simd_cross(right, forward)
        // Just wide enough to hold the character, so the pixels aren't wasted.
        let tanHalf = min(max(radius * 1.25 / distance, 0.02), 4)

        let depth = rasterize(geometry: geometry, eye: eye, right: right, up: up, forward: forward,
                              tanHalf: tanHalf, size: size)
        return VisibilityMap(size: size, eye: eye, right: right, up: up, forward: forward,
                             tanHalf: tanHalf, depth: depth)
    }

    private static func rasterize(geometry: CharacterGeometry, eye: Vec3, right: Vec3, up: Vec3,
                                  forward: Vec3, tanHalf: Float, size: Int) -> [Float] {
        var depth = [Float](repeating: .greatestFiniteMagnitude, count: size * size)
        let positions = geometry.render.positions
        let indices = geometry.render.indices
        let half = Float(size) * 0.5

        @inline(__always) func project(_ p: Vec3) -> Vec3 {
            let offset = p - eye
            let z = simd_dot(offset, forward)
            guard z > 1e-4 else { return Vec3(0, 0, -1) }
            return Vec3(simd_dot(offset, right) / (z * tanHalf) * half + half,
                        half - simd_dot(offset, up) / (z * tanHalf) * half,
                        z)
        }

        depth.withUnsafeMutableBufferPointer { buffer in
            var triangle = 0
            while triangle + 2 < indices.count {
                let a = project(positions[Int(indices[triangle])])
                let b = project(positions[Int(indices[triangle + 1])])
                let c = project(positions[Int(indices[triangle + 2])])
                triangle += 3
                guard a.z > 0, b.z > 0, c.z > 0 else { continue }

                let minX = max(Int(floor(min(a.x, b.x, c.x))), 0)
                let maxX = min(Int(ceil(max(a.x, b.x, c.x))), size - 1)
                let minY = max(Int(floor(min(a.y, b.y, c.y))), 0)
                let maxY = min(Int(ceil(max(a.y, b.y, c.y))), size - 1)
                guard minX <= maxX, minY <= maxY else { continue }

                let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
                let nearest = min(a.z, b.z, c.z)
                if abs(area) < 1e-8 {
                    // A hairline triangle on screen still covers its pixels.
                    for y in minY...maxY {
                        for x in minX...maxX {
                            let index = y * size + x
                            if nearest < buffer[index] { buffer[index] = nearest }
                        }
                    }
                    continue
                }

                for y in minY...maxY {
                    let py = Float(y) + 0.5
                    for x in minX...maxX {
                        let px = Float(x) + 0.5
                        let w0 = ((b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y)) / area
                        let w1 = ((px - a.x) * (c.y - a.y) - (c.x - a.x) * (py - a.y)) / area
                        let w2 = 1 - w0 - w1
                        guard w0 >= -0.002, w1 >= -0.002, w2 >= -0.002 else { continue }
                        let z = a.z * w2 + b.z * w1 + c.z * w0
                        let index = y * size + x
                        if z < buffer[index] { buffer[index] = z }
                    }
                }
            }
        }
        return depth
    }

    /// Pixel coordinates plus distance along the view direction.
    @inline(__always) private func project(_ p: Vec3) -> Vec3 {
        let offset = p - eye
        let z = simd_dot(offset, forward)
        guard z > 1e-4 else { return Vec3(0, 0, -1) }
        let half = Float(size) * 0.5
        let x = simd_dot(offset, right) / (z * tanHalf) * half + half
        let y = half - simd_dot(offset, up) / (z * tanHalf) * half
        return Vec3(x, y, z)
    }

    /// True if `point` is the nearest surface along its own line of sight (within `bias`).
    @inline(__always) func isVisible(_ point: Vec3, bias: Float = 0.004) -> Bool {
        let projected = project(point)
        guard projected.z > 0 else { return false }
        let x = Int(projected.x), y = Int(projected.y)
        guard x >= 0, x < size, y >= 0, y < size else { return true }
        let nearest = depth[y * size + x]
        return projected.z <= nearest + bias
    }
}
