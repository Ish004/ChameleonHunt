//
//  CharacterMask.swift
//  Where the character is on screen and how far away it is: a coarse depth picture of
//  it, drawn in the occluder's own grid.
//
//  This is what stops the occluder from eating the character. LiDAR depth is only good
//  to a few centimeters, and it gets worse with range, off-angle surfaces and white
//  glossy furniture — while the character is deliberately placed flush against real
//  surfaces (6 mm off a wall when it clings to one). So the very surface it is hiding
//  against reads as *nearer* than the character on maybe half the cells, and the
//  occluder chops lumps out of it — a different set of lumps every frame, which reads
//  as violent flickering and gives the hiding spot away instantly.
//
//  No amount of smoothing fixes that, because the error is the same size as the gap
//  being measured. Instead the occluder compares itself against this mask and keeps
//  only what is *clearly* in front of the character, dropping anything within a few
//  centimeters of it. Genuine occluders — a chair leg, a couch, a leaf 20 cm in front
//  — are unaffected; the surface the character is resting on can never erase it.
//
//  Depths are distances along the camera's -Z axis, the same quantity ARKit's depth
//  map reports, so the two are directly comparable.
//

import Foundation
import simd

/// A low-detail, slightly fattened copy of the character, cheap enough to rasterize
/// every frame. Being fatter than the real thing is deliberate: the mask erring
/// outward costs a little genuine occlusion right at the silhouette, while erring
/// inward brings back exactly the flicker this exists to prevent.
struct MaskMesh: Sendable {
    var positions: [Vec3] = []
    var indices: [UInt32] = []

    var isEmpty: Bool { indices.count < 3 }

    init(positions: [Vec3] = [], indices: [UInt32] = []) {
        self.positions = positions
        self.indices = indices
    }

    /// Triangulated from a quad mesh.
    init(quads mesh: QuadMesh) {
        positions = mesh.positions
        indices.reserveCapacity(mesh.quads.count * 6)
        for quad in mesh.quads {
            let a = UInt32(quad[0]), b = UInt32(quad[1]), c = UInt32(quad[2]), d = UInt32(quad[3])
            indices.append(contentsOf: [a, b, c, a, c, d])
        }
    }
}

struct CharacterMask: Sendable {

    let grid: DepthSurface.Grid
    /// Nearest character surface per cell; `.greatestFiniteMagnitude` where the
    /// character doesn't cover the cell.
    private(set) var depth: [Float]
    /// False when the character is off screen, so callers can skip the whole guard.
    private(set) var covers = false

    /// - Parameters:
    ///   - characterToCamera: character space → camera space.
    ///   - k: intrinsics (fx, fy, cx, cy) in depth-map pixels.
    static func build(mesh: MaskMesh, characterToCamera: simd_float4x4,
                      intrinsics k: SIMD4<Float>, grid: DepthSurface.Grid) -> CharacterMask {
        var depth = [Float](repeating: .greatestFiniteMagnitude, count: grid.cellCount)
        guard !mesh.isEmpty else { return CharacterMask(grid: grid, depth: depth, covers: false) }

        let columns = grid.columns, rows = grid.rows
        var covers = false

        // Project once per vertex: the mesh is small and every triangle uses several.
        var projected = [Vec3](repeating: .zero, count: mesh.positions.count)
        for (i, p) in mesh.positions.enumerated() {
            let local = characterToCamera.transformPoint(p)
            let d = -local.z
            guard d > 0.05 else { projected[i] = Vec3(0, 0, -1); continue }
            let pixelX = local.x / d * k.x + k.z
            let pixelY = k.w - local.y / d * k.y
            let cell = grid.cell(atPixelX: pixelX, pixelY: pixelY)
            projected[i] = Vec3(cell.x, cell.y, d)
        }

        depth.withUnsafeMutableBufferPointer { buffer in
            var t = 0
            while t + 2 < mesh.indices.count {
                let a = projected[Int(mesh.indices[t])]
                let b = projected[Int(mesh.indices[t + 1])]
                let c = projected[Int(mesh.indices[t + 2])]
                t += 3
                guard a.z > 0, b.z > 0, c.z > 0 else { continue }

                // Half a cell of bleed, so a triangle that only clips a cell's corner
                // still claims it.
                let minX = max(Int(floor(min(a.x, b.x, c.x))), 0)
                let maxX = min(Int(ceil(max(a.x, b.x, c.x))), columns - 1)
                let minY = max(Int(floor(min(a.y, b.y, c.y))), 0)
                let maxY = min(Int(ceil(max(a.y, b.y, c.y))), rows - 1)
                guard minX <= maxX, minY <= maxY else { continue }

                let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
                let nearest = min(a.z, b.z, c.z)
                if abs(area) < 1e-7 {
                    // Edge-on: it still covers the cells it crosses.
                    for y in minY...maxY {
                        for x in minX...maxX {
                            let i = y * columns + x
                            if nearest < buffer[i] { buffer[i] = nearest }
                        }
                    }
                    covers = true
                    continue
                }

                for y in minY...maxY {
                    let py = Float(y)
                    for x in minX...maxX {
                        let px = Float(x)
                        let w0 = ((b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y)) / area
                        let w1 = ((px - a.x) * (c.y - a.y) - (c.x - a.x) * (py - a.y)) / area
                        let w2 = 1 - w0 - w1
                        guard w0 >= -0.5, w1 >= -0.5, w2 >= -0.5 else { continue }
                        let z = a.z * w2 + b.z * w1 + c.z * w0
                        let i = y * columns + x
                        if z < buffer[i] { buffer[i] = z }
                        covers = true
                    }
                }
            }
        }

        guard covers else { return CharacterMask(grid: grid, depth: depth, covers: false) }

        // Grow by a cell: the occluder samples a whole block of depth pixels per cell,
        // so a cell the character only partly covers still gets that block's nearest
        // reading and would otherwise be free to chop the edge off.
        var grown = depth
        for r in 0..<rows {
            for c in 0..<columns {
                var nearest = depth[r * columns + c]
                for dr in -1...1 {
                    let rr = r + dr
                    guard rr >= 0, rr < rows else { continue }
                    for dc in -1...1 where dr != 0 || dc != 0 {
                        let cc = c + dc
                        guard cc >= 0, cc < columns else { continue }
                        nearest = min(nearest, depth[rr * columns + cc])
                    }
                }
                grown[r * columns + c] = nearest
            }
        }
        return CharacterMask(grid: grid, depth: grown, covers: true)
    }

    /// True when `depth` (a LiDAR reading, before any push-back) is far enough in front
    /// of the character at this cell to be allowed to hide it.
    @inline(__always) func allowsOccluder(cell: Int, depth value: Float, clearance: Float) -> Bool {
        let character = depth[cell]
        guard character < .greatestFiniteMagnitude else { return true }
        return value <= character - clearance
    }
}
