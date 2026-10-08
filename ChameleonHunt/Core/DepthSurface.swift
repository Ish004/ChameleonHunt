//
//  DepthSurface.swift
//  Turns a LiDAR depth map into a triangle surface in world space: the shape of
//  whatever real stuff the camera currently sees. Rendered with RealityKit's
//  OcclusionMaterial, it hides any virtual content behind it — a couch, a chair
//  leg, the leaves of a plant in front of the hidden character.
//
//  Rebuilding it from raw depth every frame makes hidden things flicker: LiDAR depth
//  is noisy and drops out exactly where it matters (table slats, fan blades), so gaps
//  open and close frame to frame and the flickering character gives itself away. Four
//  things keep it steady:
//
//  - Nearest-wins sampling: each cell takes the closest depth in its block, so thin
//    foreground objects survive rather than being averaged away.
//  - Memory anchored in the world: each cell remembers the point it saw, and that
//    point is reprojected into the next frame rather than left sitting on the screen.
//    A blade or slat that flickers in and out of the depth map keeps occluding, while
//    panning the iPad no longer smears stale near-depth across the view — which used
//    to drag chunks of furniture over the character every time the seeker moved.
//  - Pinhole filling: a cell surrounded by nearer ones is filled in, closing dropouts
//    inside solid objects while leaving silhouettes and real gaps (between table
//    slats) alone.
//  - Character clearance: cells that aren't clearly in front of the character are
//    dropped (see CharacterMask). Depth error is several centimeters; the gap between
//    the character and the surface it hides against is millimeters. Without this the
//    surface it is resting on wins that argument about half the time, per cell, per
//    frame.
//
//  Camera conventions match ARKit (see KeyframeBaker): +X right, +Y up, looking
//  down -Z; intrinsics in depth-map pixels with row 0 at the top.
//

import Foundation
import simd

enum DepthSurface {

    /// The occluder's sampling grid over the depth map: one cell per block of pixels.
    /// Shared with CharacterMask so both speak in the same cells.
    struct Grid: Sendable, Equatable {
        let columns: Int
        let rows: Int
        let width: Int
        let height: Int
        /// Blocks round up and overlap by a pixel: no depth pixel is skipped, and a
        /// thin stem or leaf always lands in at least one block.
        let blockWidth: Int
        let blockHeight: Int

        init(columns: Int, rows: Int, width: Int, height: Int) {
            self.columns = max(1, columns)
            self.rows = max(1, rows)
            self.width = max(1, width)
            self.height = max(1, height)
            blockWidth = max(1, (self.width + self.columns - 1) / self.columns + 1)
            blockHeight = max(1, (self.height + self.rows - 1) / self.rows + 1)
        }

        var cellCount: Int { columns * rows }

        /// Pixel that cell (column, row) is measured at.
        @inline(__always) func pixelCenter(column: Int, row: Int) -> (x: Float, y: Float) {
            (Float(column * width / columns) + Float(blockWidth) * 0.5,
             Float(row * height / rows) + Float(blockHeight) * 0.5)
        }

        /// Fractional cell coordinates of a pixel — the inverse of `pixelCenter`.
        @inline(__always) func cell(atPixelX x: Float, pixelY y: Float) -> (x: Float, y: Float) {
            ((x - Float(blockWidth) * 0.5) * Float(columns) / Float(width),
             (y - Float(blockHeight) * 0.5) * Float(rows) / Float(height))
        }
    }

    struct Settings: Sendable {
        var columns = 160
        var rows = 120
        /// Push every surface this much away from the camera before it occludes, to
        /// absorb depth noise, plus this much again per meter of range (LiDAR error
        /// grows with distance).
        var pushBack: Float = 0.03
        var pushBackPerMeter: Float = 0.02
        var maxDepth: Float = 5
        /// Neighbouring depths further apart than this (plus a fraction of the depth) aren't joined.
        var discontinuity: Float = 0.05
        var relativeDiscontinuity: Float = 0.05
        /// A real surface must be at least this much nearer than the character before
        /// it is allowed to hide any of it. Depth readings wobble by a couple of
        /// centimeters and the character sits millimeters off the surface it hides
        /// against, so anything less than this is noise, not occlusion.
        var characterClearance: Float = 0.06
        /// How fast a cell's depth may recede when the real surface moves away or the
        /// reading drops out, in meters per second. Slow on purpose: a fan blade or a
        /// table slat that the LiDAR only catches every few frames must keep occluding
        /// in between, and a stale occluder is far less noticeable than a flickering
        /// character.
        var releaseSpeed: Float = 0.35
        /// Extra release per meter/second of camera movement (plus rad/s of rotation).
        /// Small, because memory is reprojected rather than left on the screen; it only
        /// covers the error in that reprojection.
        var releasePerMotion: Float = 0.6
        /// After a cell sees something near, it holds that depth for this long before
        /// it starts receding at all. Covers a blade sweeping past or a slat the depth
        /// map loses for a few frames.
        var holdSeconds: Float = 0.35
        /// The hold shortens a little as the iPad moves.
        var holdMotionFalloff: Float = 0.2
        /// Close pinholes by taking the nearest depth of the surrounding cells.
        var dilate = true
        /// Carry each cell's memory by the point it saw in the room, rather than leaving
        /// it sitting at the same place on the screen. Off is the old behaviour, kept
        /// because the regression test measures the difference between the two.
        var worldAnchoredMemory = true
    }

    /// Remembers what each cell saw — and *where it was in the room* — so thin, flickery
    /// objects keep occluding without the memory sliding around the screen when the
    /// camera moves.
    struct Stabilizer {
        var depths: [Float] = []
        /// World position of each remembered reading, for reprojection.
        var points: [Vec3] = []
        /// Seconds each cell still holds its depth before it may recede.
        var holds: [Float] = []
        var lastTimestamp: TimeInterval = 0

        /// Output: the share of the character the occluder is covering this frame.
        /// Drives how the character is drawn — see CharacterPresenter.
        var characterCoverage: Float = 0

        mutating func reset() {
            depths.removeAll(keepingCapacity: true)
            points.removeAll(keepingCapacity: true)
            holds.removeAll(keepingCapacity: true)
            lastTimestamp = 0
            characterCoverage = 0
        }
    }

    /// Fills `positions` (columns × rows, world space) and `indices` (triangles).
    /// - Parameters:
    ///   - confidence: ARKit's confidence map (0 low … 2 high), same size as `depth`.
    ///     Low-confidence cells hold their previous value instead of punching a hole.
    ///   - motion: camera speed in m/s plus rotation in rad/s, used to release memory faster.
    ///   - characterMask: where the character is, so the occluder can refuse to hide it
    ///     with anything that isn't convincingly in front of it.
    /// - Returns: bounds of the valid vertices, or nil if nothing valid was seen.
    @discardableResult
    static func build(depth: UnsafeBufferPointer<Float32>, width: Int, height: Int, bytesPerRowInPixels stride: Int,
                      confidence: UnsafeBufferPointer<UInt8>? = nil, confidenceStride: Int = 0,
                      intrinsics k: SIMD4<Float>, cameraToWorld: simd_float4x4, settings s: Settings,
                      stabilizer: inout Stabilizer, timestamp: TimeInterval = 0, motion: Float = 0,
                      characterMask: CharacterMask? = nil,
                      positions: inout [Vec3], indices: inout [UInt32]) -> (min: Vec3, max: Vec3)? {
        let grid = Grid(columns: s.columns, rows: s.rows, width: width, height: height)
        let columns = grid.columns, rows = grid.rows
        let cellCount = grid.cellCount
        if positions.count != cellCount { positions = [Vec3](repeating: .zero, count: cellCount) }
        if stabilizer.depths.count != cellCount { stabilizer.depths = [Float](repeating: 0, count: cellCount) }
        if stabilizer.points.count != cellCount { stabilizer.points = [Vec3](repeating: .zero, count: cellCount) }
        if stabilizer.holds.count != cellCount { stabilizer.holds = [Float](repeating: 0, count: cellCount) }
        indices.removeAll(keepingCapacity: true)

        let blockWidth = grid.blockWidth, blockHeight = grid.blockHeight
        let elapsed = stabilizer.lastTimestamp > 0 ? Float(min(max(timestamp - stabilizer.lastTimestamp, 0), 0.5)) : 1
        stabilizer.lastTimestamp = timestamp
        let release = max(0.005, (s.releaseSpeed + s.releasePerMotion * motion) * elapsed)
        let hold = max(0, s.holdSeconds * (1 - s.holdMotionFalloff * motion))

        // 0. Carry the memory into this frame by reprojecting the points it remembers.
        //    A cell remembers a place in the room, not a place on the screen, so turning
        //    the iPad moves the memory with the world instead of dragging it across the
        //    view. Points that have left the frame are simply forgotten.
        var rememberedDepth = [Float](repeating: 0, count: cellCount)
        var rememberedHold = [Float](repeating: 0, count: cellCount)
        let worldToCamera = cameraToWorld.inverse
        if !s.worldAnchoredMemory {
            rememberedDepth = stabilizer.depths
            rememberedHold = stabilizer.holds
        }
        for i in 0..<cellCount where s.worldAnchoredMemory && stabilizer.depths[i] > 0 {
            let local = worldToCamera.transformPoint(stabilizer.points[i])
            let d = -local.z
            guard d > 0.05, d <= s.maxDepth else { continue }
            let cell = grid.cell(atPixelX: local.x / d * k.x + k.z, pixelY: k.w - local.y / d * k.y)
            let c = Int(cell.x.rounded()), r = Int(cell.y.rounded())
            guard c >= 0, c < columns, r >= 0, r < rows else { continue }
            let j = r * columns + c
            if rememberedDepth[j] == 0 || d < rememberedDepth[j] {
                rememberedDepth[j] = d
                rememberedHold[j] = stabilizer.holds[i]
            }
        }

        // 1. Nearest valid depth per cell, then blend with what the cell remembered.
        var stable = [Float](repeating: 0, count: cellCount)
        for r in 0..<rows {
            let y0 = r * height / rows
            for c in 0..<columns {
                let x0 = c * width / columns
                var nearest = Float.greatestFiniteMagnitude
                for y in y0..<min(y0 + blockHeight, height) {
                    for x in x0..<min(x0 + blockWidth, width) {
                        if let confidence, confidence[y * confidenceStride + x] < 1 { continue }
                        let value = depth[y * stride + x]
                        if value.isFinite && value > 0.05 && value < nearest { nearest = value }
                    }
                }

                let index = r * columns + c
                let remembered = rememberedDepth[index]
                var value: Float
                var remainingHold = max(0, rememberedHold[index] - elapsed)

                if nearest <= s.maxDepth, remembered == 0 || nearest <= remembered + release {
                    // Something at least as near as remembered: take it and hold it.
                    value = remembered > 0 ? min(nearest, remembered + release) : nearest
                    remainingHold = hold
                } else if remembered > 0 {
                    // Only farther readings, or none at all (dropout, low confidence).
                    // Hold briefly, then let the memory recede rather than opening a hole.
                    if remainingHold > 0 {
                        value = remembered
                    } else {
                        value = min(remembered + release, nearest <= s.maxDepth ? nearest : .greatestFiniteMagnitude)
                        if value > s.maxDepth { value = 0 }
                    }
                } else {
                    value = nearest <= s.maxDepth ? nearest : 0
                }

                stabilizer.depths[index] = value
                stabilizer.holds[index] = remainingHold
                stable[index] = value
                if value > 0 {
                    let pixel = grid.pixelCenter(column: c, row: r)
                    stabilizer.points[index] = cameraToWorld.transformPoint(
                        Vec3((pixel.x - k.z) / k.x * value, -(pixel.y - k.w) / k.y * value, -value))
                }
            }
        }

        // 2. Close pinholes — but only true pinholes. A cell is filled from its
        //    neighbours when it is surrounded by nearer ones (a dropout or a speck of
        //    noise inside a solid object). Cells along a real silhouette have nearer
        //    neighbours on one side only, so edges stay crisp and genuine gaps — the
        //    space between table slats — stay see-through.
        var cellDepth = stable
        if s.dilate {
            for r in 0..<rows {
                for c in 0..<columns {
                    let index = r * columns + c
                    let current = stable[index]
                    var nearest = Float.greatestFiniteMagnitude
                    var nearerNeighbours = 0
                    for dr in -1...1 {
                        let rr = r + dr
                        guard rr >= 0, rr < rows else { continue }
                        for dc in -1...1 where dr != 0 || dc != 0 {
                            let cc = c + dc
                            guard cc >= 0, cc < columns else { continue }
                            let neighbour = stable[rr * columns + cc]
                            guard neighbour > 0 else { continue }
                            if current == 0 || neighbour < current - 0.03 {
                                nearerNeighbours += 1
                                nearest = min(nearest, neighbour)
                            }
                        }
                    }
                    if nearerNeighbours >= 6, nearest < .greatestFiniteMagnitude {
                        cellDepth[index] = nearest
                    }
                }
            }
        }

        // 3. Over the character, keep only what is clearly in front of it. The occluder
        //    keeps following the real surface underneath (the memory above is untouched)
        //    — it just isn't allowed to draw here. Also measure how much of the character
        //    is left covered, which is what decides how it gets drawn at all.
        //
        //    Temporal filtering belongs to that decision, not to individual cells: a cell
        //    is a few square centimeters of a moving view, and anything that tries to
        //    track one across frames is guessing. VisibilityPolicy does the waiting, on
        //    the one number that is actually stable.
        if let characterMask, characterMask.covers, characterMask.grid == grid {
            var cells = 0, covered = 0
            for i in 0..<cellCount {
                guard characterMask.depth[i] < .greatestFiniteMagnitude else { continue }
                cells += 1
                let allowed = cellDepth[i] > 0
                    && characterMask.allowsOccluder(cell: i, depth: cellDepth[i], clearance: s.characterClearance)
                if allowed { covered += 1 } else { cellDepth[i] = 0 }
            }
            stabilizer.characterCoverage = cells > 0 ? Float(covered) / Float(cells) : 0
        } else {
            stabilizer.characterCoverage = 0
        }

        // 4. Unproject to world space, pushed back along each ray.
        var lo = Vec3(repeating: .greatestFiniteMagnitude)
        var hi = Vec3(repeating: -.greatestFiniteMagnitude)
        var anyValid = false
        for r in 0..<rows {
            for c in 0..<columns {
                let index = r * columns + c
                let value = cellDepth[index]
                guard value > 0 else { continue }
                let pixel = grid.pixelCenter(column: c, row: r)
                let d = value + s.pushBack + s.pushBackPerMeter * value
                let world = cameraToWorld.transformPoint(
                    Vec3((pixel.x - k.z) / k.x * d, -(pixel.y - k.w) / k.y * d, -d))
                positions[index] = world
                lo = simd_min(lo, world)
                hi = simd_max(hi, world)
                anyValid = true
            }
        }

        @inline(__always) func joinable(_ a: Int, _ b: Int, _ c: Int) -> Bool {
            let da = cellDepth[a], db = cellDepth[b], dc = cellDepth[c]
            guard da > 0, db > 0, dc > 0 else { return false }
            let near = min(da, db, dc), far = max(da, db, dc)
            return far - near <= s.discontinuity + s.relativeDiscontinuity * near
        }

        for r in 0..<(rows - 1) {
            for c in 0..<(columns - 1) {
                let v00 = r * columns + c, v10 = v00 + 1
                let v01 = v00 + columns, v11 = v01 + 1
                // Counter-clockwise as seen from the camera.
                if joinable(v00, v11, v10) { indices.append(contentsOf: [UInt32(v00), UInt32(v11), UInt32(v10)]) }
                if joinable(v00, v01, v11) { indices.append(contentsOf: [UInt32(v00), UInt32(v01), UInt32(v11)]) }
            }
        }

        return anyValid ? (lo, hi) : nil
    }

    /// A camera-facing square `distance` meters in front of the camera, big enough to
    /// fill the view. Used by the render check to prove occlusion works.
    static func testWall(distance: Float, cameraToWorld: simd_float4x4) -> (positions: [Vec3], indices: [UInt32]) {
        let size = distance * 3
        let corners: [Vec3] = [[-size, -size, -distance], [size, -size, -distance],
                               [size, size, -distance], [-size, size, -distance]]
        return (corners.map { cameraToWorld.transformPoint($0) }, [0, 1, 2, 0, 2, 3])
    }
}
