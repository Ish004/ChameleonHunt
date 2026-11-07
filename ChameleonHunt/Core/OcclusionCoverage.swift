//
//  OcclusionCoverage.swift
//  How much of a chameleon is behind something real, from where the camera is now.
//
//  This replaced per-pixel occlusion. Cutting the chameleon along the edge of whatever is
//  in front of it is right in principle, but that edge comes from a depth measurement a
//  few centimetres uncertain, so it crawls — and anything that crawls in the corner of a
//  seeker's eye gets looked at. Players said it plainly: better that it vanish behind the
//  sofa than glitch at the edge of it. So there is no edge any more. Each chameleon gets
//  one number — the share of it that real surfaces are clearly in front of — and
//  VisibilityPolicy turns that into shown or hidden, fading between the two.
//
//  One pass over the depth map serves every chameleon in the room, which is what makes
//  hiding several at once affordable.
//

import Foundation
import simd

enum OcclusionCoverage {

    /// The nearest confident depth in each cell of a coarse grid over the depth map.
    struct Cells: Sendable {
        let grid: DepthSurface.Grid
        /// 0 where nothing was measured.
        let nearest: [Float]
        /// Share of each cell's depth pixels the sensor wasn't sure of (empty without a
        /// confidence map). High over glass, mirrors and glossy surfaces.
        var unsure: [Float] = []
    }

    static func sample(depth: UnsafeBufferPointer<Float32>, width: Int, height: Int, stride: Int,
                       confidence: UnsafeBufferPointer<UInt8>? = nil, confidenceStride: Int = 0,
                       columns: Int = 96, rows: Int = 72) -> Cells {
        let grid = DepthSurface.Grid(columns: columns, rows: rows, width: width, height: height)
        var nearest = [Float](repeating: 0, count: grid.cellCount)
        var unsure = [Float](repeating: 0, count: confidence == nil ? 0 : grid.cellCount)
        for r in 0..<grid.rows {
            let y0 = r * height / grid.rows
            for c in 0..<grid.columns {
                let x0 = c * width / grid.columns
                var best = Float.greatestFiniteMagnitude
                var doubtful = 0, total = 0
                for y in y0..<min(y0 + grid.blockHeight, height) {
                    for x in x0..<min(x0 + grid.blockWidth, width) {
                        total += 1
                        if let confidence, confidence[y * confidenceStride + x] < 1 { doubtful += 1; continue }
                        let d = depth[y * stride + x]
                        if d.isFinite, d > 0.05, d < best { best = d }
                    }
                }
                nearest[r * grid.columns + c] = best < 6 ? best : 0
                if confidence != nil { unsure[r * grid.columns + c] = Float(doubtful) / Float(max(total, 1)) }
            }
        }
        return Cells(grid: grid, nearest: nearest, unsure: unsure)
    }

    /// Share of the chameleon's cells with a real surface clearly in front of it.
    /// - Parameter clearance: how much nearer a surface must be to count. The chameleon
    ///   sits millimetres off whatever it's hiding on, and depth is only good to a few
    ///   centimetres, so anything closer than this is the surface it's sitting on.
    /// How unsure the sensor is about the real surface behind the chameleon — its own
    /// cells plus a ring round them. Glass, mirrors and glossy things read high. Nil
    /// without a confidence map or when it isn't on screen.
    static func unsureShare(behind mask: CharacterMask, in cells: Cells) -> Float? {
        guard mask.covers, mask.grid == cells.grid, cells.unsure.count == cells.grid.cellCount else { return nil }
        let columns = cells.grid.columns, rows = cells.grid.rows
        var sum: Float = 0, n = 0
        for i in 0..<cells.grid.cellCount where mask.depth[i] < .greatestFiniteMagnitude {
            let column = i % columns, row = i / columns
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = column + dx, y = row + dy
                    guard x >= 0, y >= 0, x < columns, y < rows else { continue }
                    sum += cells.unsure[y * columns + x]
                    n += 1
                }
            }
        }
        return n > 0 ? sum / Float(n) : nil
    }

    static func coverage(of mask: CharacterMask, in cells: Cells, clearance: Float = 0.06) -> Float {
        guard mask.covers, mask.grid == cells.grid else { return 0 }
        var total = 0, covered = 0
        for i in 0..<cells.grid.cellCount {
            let character = mask.depth[i]
            guard character < .greatestFiniteMagnitude else { continue }
            total += 1
            let real = cells.nearest[i]
            if real > 0, real <= character - clearance { covered += 1 }
        }
        return total > 0 ? Float(covered) / Float(total) : 0
    }
}
