//
//  PaintCanvas.swift
//  The character's paint job: an RGBA atlas plus the brush engine that edits it.
//
//  All brushes work in 3D. A dab is a sphere around the point the Pencil ray hit;
//  every texel whose 3D position falls inside it, faces the viewer, and isn't
//  hidden behind another body part gets blended toward the brush color. The
//  color can be a flat color, or — for the camo brush and auto-camouflage — a
//  per-texel color looked up by ray-casting into the scanned room.
//
//  Undo stores only the texels a stroke changed, not whole-texture snapshots.
//
//  Threading: mutated from the main thread, except `applyToAllTexels`, which the
//  studio runs on a background task while the UI is blocked.
//

import Foundation
import simd

final class PaintCanvas: @unchecked Sendable {

    let geometry: CharacterGeometry
    /// RGBA8 sRGB, `atlasWidth * atlasHeight * 4`.
    private(set) var pixels: [UInt8]

    static let baseColor: Color3 = [0.95, 0.95, 0.94]

    private var dirty: DirtyRect?
    private var strokeMarks: [UInt32]
    private var strokeID: UInt32 = 0
    private var current: StrokeRecord?
    private var undoStack: [StrokeRecord] = []
    private var redoStack: [StrokeRecord] = []

    private struct StrokeRecord {
        var texels: [Int32] = []
        var before: [UInt32] = []
        var after: [UInt32] = []
        var bytes: Int { texels.count * 12 }
    }

    /// Undo history budget. Auto-camouflage alone can touch a million texels.
    private let undoByteBudget = 256 * 1024 * 1024

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(geometry: CharacterGeometry) {
        self.geometry = geometry
        let count = geometry.atlasWidth * geometry.atlasHeight
        pixels = [UInt8](repeating: 0, count: count * 4)
        strokeMarks = [UInt32](repeating: 0, count: count)
        let (r, g, b) = packRGBA(PaintCanvas.baseColor)
        for i in 0..<count {
            pixels[i * 4] = r; pixels[i * 4 + 1] = g; pixels[i * 4 + 2] = b; pixels[i * 4 + 3] = 255
        }
        dirty = DirtyRect(minX: 0, minY: 0, maxX: geometry.atlasWidth - 1, maxY: geometry.atlasHeight - 1)
    }

    /// Replaces the whole atlas, before any painting has happened. Undo history stays
    /// empty on purpose: this is the starting point, not an edit.
    func setPixels(_ newPixels: [UInt8]) {
        guard newPixels.count == pixels.count else { return }
        pixels = newPixels
        markAllDirty()
    }

    /// Returns and clears the region changed since the last call.
    func takeDirtyRect() -> DirtyRect? {
        defer { dirty = nil }
        return dirty
    }

    func markAllDirty() {
        dirty = DirtyRect(minX: 0, minY: 0, maxX: geometry.atlasWidth - 1, maxY: geometry.atlasHeight - 1)
    }

    // MARK: - Strokes

    func beginStroke() {
        if current != nil { endStroke() }
        strokeID &+= 1
        if strokeID == 0 {
            // Wrapped: reset marks so stale IDs can't collide.
            for i in strokeMarks.indices { strokeMarks[i] = 0 }
            strokeID = 1
        }
        current = StrokeRecord()
    }

    func endStroke() {
        guard var record = current else { return }
        current = nil
        guard !record.texels.isEmpty else { return }
        record.after = record.texels.map { packed(Int($0)) }
        pushUndo(record)
    }

    /// Throws away the stroke in progress as if it never happened — for a finger that
    /// turned out to be the first of two, about to turn the model rather than paint it.
    func cancelStroke() {
        guard let record = current else { return }
        current = nil
        restore(record.texels, record.before)
    }

    /// One brush dab.
    /// - Parameters:
    ///   - center: brush center in character space.
    ///   - radius: brush radius in character-space meters.
    ///   - eye: camera position in character space (for facing / occlusion tests).
    ///   - opacity: 0...1 strength of this dab.
    ///   - hardness: 0 = soft airbrush falloff, 1 = hard edge.
    ///   - fadeAtGrazingAngles: weaken paint on surfaces seen edge-on. Right for a
    ///     flat brush (no smearing down the sides); wrong for camouflage, where the
    ///     silhouette edge is exactly what must blend in.
    ///   - color: per-texel target color; return nil to leave a texel untouched.
    ///   - visibility: depth of the character from the painter's viewpoint. Far cheaper
    ///     than a ray cast per texel for big brushes; falls back to ray casts when nil.
    func dab(center: Vec3, radius: Float, eye: Vec3, opacity: Float, hardness: Float,
             fadeAtGrazingAngles: Bool = true, visibility: VisibilityMap? = nil,
             color: (_ texel: Int, _ position: Vec3) -> Color3?) {
        guard current != nil, radius > 0, opacity > 0 else { return }
        let width = geometry.atlasWidth
        let radiusSquared = radius * radius

        geometry.grid.forEachTexel(near: center, radius: radius) { texel in
            let p = geometry.texelPositions[texel]
            let d2 = simd_distance_squared(p, center)
            guard d2 <= radiusSquared else { return }

            let normal = geometry.texelNormals[texel]
            let toEye = eye - p
            let eyeDistance = simd_length(toEye)
            let viewDirection = toEye / eyeDistance
            let facing = simd_dot(normal, viewDirection)
            guard facing > (fadeAtGrazingAngles ? 0.02 : -0.02) else { return }

            // Don't paint through an arm onto the chest behind it.
            if let visibility {
                if !visibility.isVisible(p) { return }
            } else if geometry.bvh.occluded(origin: p + normal * 0.002, direction: viewDirection,
                                            tMin: 0, tMax: eyeDistance) { return }

            let x = d2.squareRoot() / radius
            let falloff: Float = x <= hardness ? 1 : 1 - smoothstep(hardness, 1, x)
            let alpha = falloff * opacity * (fadeAtGrazingAngles ? min(1, max(0, facing) * 4) : 1)
            guard alpha > 0.002, let target = color(texel, p) else { return }

            record(texel)
            blend(texel: texel, toward: target, alpha: alpha)
            dirty.include(x: texel % width, y: texel / width)
        }
    }

    /// Eyedropper on the character itself: the color of the texel nearest `point`.
    func color(near point: Vec3) -> Color3? {
        var best: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        geometry.grid.forEachTexel(near: point, radius: 0.01) { texel in
            let d = simd_distance_squared(geometry.texelPositions[texel], point)
            if d < bestDistance { bestDistance = d; best = texel }
        }
        guard let best else { return nil }
        let i = best * 4
        return Color3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
    }

    /// Recolors every texel in parallel as one undoable step.
    /// `color` must be thread-safe; returning nil keeps the texel's current color.
    func applyToAllTexels(_ color: @Sendable (_ texel: Int, _ position: Vec3, _ normal: Vec3) -> Color3?,
                          progress: @Sendable (Float) -> Void) {
        if current != nil { endStroke() }
        let texels = geometry.validTexels
        var record = StrokeRecord()
        record.texels = texels
        record.before = texels.map { packed(Int($0)) }

        let geometry = self.geometry
        let completed = Counter()
        pixels.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            Parallel.forEachChunk(count: texels.count, minimumChunk: 2048) { range in
                for k in range {
                    let texel = Int(texels[k])
                    guard let c = color(texel, geometry.texelPositions[texel], geometry.texelNormals[texel]) else { continue }
                    let (r, g, b) = packRGBA(c)
                    out.base[texel * 4] = r
                    out.base[texel * 4 + 1] = g
                    out.base[texel * 4 + 2] = b
                }
                progress(Float(completed.add(range.count)) / Float(texels.count))
            }
        }

        record.after = texels.map { packed(Int($0)) }
        pushUndo(record)
        markAllDirty()
    }

    func fill(_ color: Color3) {
        applyToAllTexels({ _, _, _ in color }, progress: { _ in })
    }

    // MARK: - Undo

    func undo() {
        guard let record = undoStack.popLast() else { return }
        restore(record.texels, record.before)
        redoStack.append(record)
    }

    func redo() {
        guard let record = redoStack.popLast() else { return }
        restore(record.texels, record.after)
        undoStack.append(record)
    }

    private func pushUndo(_ record: StrokeRecord) {
        undoStack.append(record)
        redoStack.removeAll()
        var total = undoStack.reduce(0) { $0 + $1.bytes }
        while total > undoByteBudget, undoStack.count > 1 {
            total -= undoStack.removeFirst().bytes
        }
    }

    private func restore(_ texels: [Int32], _ values: [UInt32]) {
        let width = geometry.atlasWidth
        var rect: DirtyRect?
        for (k, texel) in texels.enumerated() {
            let t = Int(texel)
            let v = values[k]
            pixels[t * 4] = UInt8(truncatingIfNeeded: v >> 24)
            pixels[t * 4 + 1] = UInt8(truncatingIfNeeded: v >> 16)
            pixels[t * 4 + 2] = UInt8(truncatingIfNeeded: v >> 8)
            pixels[t * 4 + 3] = UInt8(truncatingIfNeeded: v)
            rect.include(x: t % width, y: t / width)
        }
        dirty.formUnion(rect)
    }

    // MARK: - Pixel helpers

    @inline(__always) private func record(_ texel: Int) {
        guard strokeMarks[texel] != strokeID else { return }
        strokeMarks[texel] = strokeID
        current?.texels.append(Int32(texel))
        current?.before.append(packed(texel))
    }

    @inline(__always) private func packed(_ texel: Int) -> UInt32 {
        let i = texel * 4
        return UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16 | UInt32(pixels[i + 2]) << 8 | UInt32(pixels[i + 3])
    }

    @inline(__always) private func blend(texel: Int, toward target: Color3, alpha: Float) {
        let i = texel * 4
        let old = Color3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
        let (r, g, b) = packRGBA(old + (target - old) * alpha)
        pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b
    }
}

// MARK: - Camouflage color sources

enum Camouflage {

    /// What the room looks like *behind* a point, seen from `eye`: continue the
    /// eye->point ray past the character until it hits the scanned environment.
    @inline(__always) static func backgroundColor(behind point: Vec3, from eye: Vec3,
                                                  environment: EnvironmentGeometry) -> Color3? {
        let offset = point - eye
        let distance = simd_length(offset)
        guard distance > 1e-4 else { return nil }
        let direction = offset / distance
        return environment.trace(origin: point + direction * 0.003, direction: direction,
                                 tMin: 0, tMax: 6)?.color
    }

    /// Where a seeker might look from, for auto-camouflage, in hide-anchor space
    /// (origin on the surface under the chameleon, +Y out of the surface).
    ///
    /// The scan's own camera positions are the best evidence, but they're all where the
    /// hider stood — above the chameleon, looking down — so on their own they can't see
    /// the lower half of its sides at all, and those came out bare. A seeker can crouch,
    /// sit on the floor, or look up from under a table, so a ring of lower viewpoints is
    /// added to fill in what the scan never saw. They count for much less than the real
    /// ones, so wherever the scan saw a texel its colours still win.
    struct Viewpoint: Sendable {
        let eye: Vec3
        let weight: Float
    }

    static func seekerViewpoints(scanned: [Vec3]) -> [Viewpoint] {
        var result = scanned.map { Viewpoint(eye: $0, weight: 1) }
        let heights: [Float] = [0.06, 0.2, 0.45, 0.8]
        let steps = 16
        for height in heights {
            for step in 0..<steps {
                let angle = Float(step) / Float(steps) * 2 * .pi + (height > 0.3 ? .pi / Float(steps) : 0)
                result.append(Viewpoint(eye: Vec3(cos(angle) * 1.2, height, sin(angle) * 1.2), weight: 0.12))
            }
        }
        return result
    }

    /// Auto-camouflage: paint each texel with what's behind it as seen from the
    /// seeker viewpoints that face it most head-on.
    ///
    /// The three best viewpoints are blended with weights that fall off steeply
    /// with angle. Snapping to a single best viewpoint instead leaves blocky
    /// patches wherever neighboring texels pick different viewpoints. Texels no
    /// viewpoint can see (the belly, pressed against the surface) take the colour of
    /// the surface right beside them, so the paint carries on down to the bottom edge.
    static func autoColor(point: Vec3, normal: Vec3, viewpoints: [Viewpoint],
                          environment: EnvironmentGeometry) -> Color3? {
        var top: [(eye: Vec3, score: Float)] = []
        top.reserveCapacity(4)
        for viewpoint in viewpoints {
            let facing = simd_dot(normal, simd_normalize(viewpoint.eye - point))
            guard facing > 0.05 else { continue }
            let f2 = facing * facing
            let score = f2 * f2 * viewpoint.weight + 1e-5
            if top.count < 3 {
                top.append((viewpoint.eye, score))
            } else if let weakest = top.indices.min(by: { top[$0].score < top[$1].score }),
                      score > top[weakest].score {
                top[weakest] = (viewpoint.eye, score)
            }
        }

        var sum = Color3.zero
        var weight: Float = 0
        for candidate in top {
            guard let color = backgroundColor(behind: point, from: candidate.eye, environment: environment) else { continue }
            sum += color * candidate.score
            weight += candidate.score
        }
        if weight > 0 { return sum / weight }
        return surfaceColor(beside: point, normal: normal, environment: environment)
    }

    /// Magic camouflage for the whole chameleon, texel by texel (indexed like the atlas;
    /// nil where there's nothing to paint). On top of `autoColor`:
    ///
    ///  - The bottom edge sits into the surface. The last couple of centimetres ease
    ///    towards the colour of the surface right beside them: from almost anywhere,
    ///    that's what's behind the bottom of a chameleon, and a line of wrong colour
    ///    along the bottom was the most common giveaway.
    ///  - A light smoothing across the body. Each texel's colour comes from a single ray,
    ///    and neighbouring rays land on slightly different spots of a noisy scan, which
    ///    left the paint speckled and patchy where it should read as one surface. Colours
    ///    within a few millimetres are averaged — but only with neighbours of a similar
    ///    colour, so real edges (the line where a wall meets the floor) stay sharp.
    ///
    /// Done in patches a couple of millimetres across rather than texel by texel: a
    /// chameleon has ~440,000 texels but a scan only has detail to about half a
    /// centimetre, so each patch is coloured once and every texel blends the patches
    /// around it. That's the smoothing too, and it takes the same time whatever size the
    /// chameleon is — texel by texel, a small one took several seconds.
    static func paintAll(geometry: CharacterGeometry, scale: Float, viewpoints: [Viewpoint],
                         environment: EnvironmentGeometry) -> [Color3?] {
        let count = geometry.atlasWidth * geometry.atlasHeight
        let texels = geometry.validTexels
        let offset = Vec3(0, SurfaceFrame.surfaceOffset, 0)
        let groundBand: Float = 0.025
        // About 2.5 mm of real chameleon, in its own units.
        let cell = min(max(0.0025 / max(scale, 0.05), 0.0015), 0.006)

        // 1. Patches: texels grouped by grid cell and which way they face.
        struct Key: Hashable { var x: Int32, y: Int32, z: Int32, facing: Int8 }
        var patchOf = [Int32](repeating: 0, count: texels.count)
        var patchIndex: [Key: Int32] = [:]
        var sumPosition: [Vec3] = [], sumNormal: [Vec3] = [], cellOf: [SIMD3<Int32>] = []
        for (k, texel) in texels.enumerated() {
            let p = geometry.texelPositions[Int(texel)], n = geometry.texelNormals[Int(texel)]
            let c = SIMD3<Int32>(Int32(floor(p.x / cell)), Int32(floor(p.y / cell)), Int32(floor(p.z / cell)))
            let a = simd_abs(n)
            let axis: Int8 = a.x > a.y ? (a.x > a.z ? 0 : 2) : (a.y > a.z ? 1 : 2)
            let facing = axis * 2 + (n[Int(axis)] < 0 ? 1 : 0)
            let key = Key(x: c.x, y: c.y, z: c.z, facing: facing)
            let id: Int32
            if let existing = patchIndex[key] { id = existing } else {
                id = Int32(sumPosition.count)
                patchIndex[key] = id
                sumPosition.append(.zero); sumNormal.append(.zero); cellOf.append(c)
            }
            sumPosition[Int(id)] += p
            sumNormal[Int(id)] += n
            patchOf[k] = id
        }
        let patches = sumPosition.count
        var patchCount = [Float](repeating: 0, count: patches)
        for id in patchOf { patchCount[Int(id)] += 1 }
        let centres = (0..<patches).map { sumPosition[$0] / patchCount[$0] }
        let normals = (0..<patches).map { simd_length(sumNormal[$0]) > 1e-6 ? simd_normalize(sumNormal[$0]) : Vec3(0, 1, 0) }

        // 2. One colour per patch, with the bottom edge eased into the surface beside it.
        var colours = [Color3?](repeating: nil, count: patches)
        colours.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            Parallel.forEachChunk(count: patches, minimumChunk: 64) { range in
                for i in range {
                    let point = centres[i] * scale + offset
                    var colour = autoColor(point: point, normal: normals[i], viewpoints: viewpoints, environment: environment)
                    let height = point.y - offset.y
                    if height < groundBand, let ground = surfaceColor(beside: point, normal: normals[i], environment: environment) {
                        let t = 0.65 * (1 - max(0, height) / groundBand)
                        colour = colour.map { $0 + (ground - $0) * t } ?? ground
                    }
                    out.base[i] = colour
                }
            }
        }

        // 3. Which patches are near which: the ones in the 27 cells around each.
        var cells: [SIMD3<Int32>: [Int32]] = [:]
        for i in 0..<patches { cells[cellOf[i], default: []].append(Int32(i)) }
        let neighbours: [[Int32]] = (0..<patches).map { i in
            var near: [Int32] = []
            let c = cellOf[i]
            for dz: Int32 in -1...1 { for dy: Int32 in -1...1 { for dx: Int32 in -1...1 {
                for j in cells[c &+ SIMD3(dx, dy, dz)] ?? [] where simd_dot(normals[Int(j)], normals[i]) > 0.2 { near.append(j) }
            } } }
            return near
        }

        // 4. Each texel blends the patches around it — nearer, facing the same way and of
        //    a similar colour count more — so there are no patch edges, speckle is
        //    averaged away, and real edges in the room stay sharp.
        let spatial = 1 / (2 * (cell * 0.7) * (cell * 0.7))
        let tonal: Float = 1 / (2 * 0.18 * 0.18)
        let patchOfTexel = patchOf, patchColours = colours
        var result = [Color3?](repeating: nil, count: count)
        result.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            Parallel.forEachChunk(count: texels.count, minimumChunk: 2048) { range in
                for k in range {
                    let texel = Int(texels[k])
                    let own = Int(patchOfTexel[k])
                    guard let ownColour = patchColours[own] else { continue }
                    let p = geometry.texelPositions[texel], n = geometry.texelNormals[texel]
                    var sum = Color3.zero
                    var weight: Float = 0
                    for j in neighbours[own] {
                        guard let colour = patchColours[Int(j)] else { continue }
                        let facing = max(0, simd_dot(normals[Int(j)], n))
                        let w = exp(-simd_distance_squared(centres[Int(j)], p) * spatial
                                    - simd_distance_squared(colour, ownColour) * tonal) * facing * facing
                        sum += colour * w
                        weight += w
                    }
                    out.base[texel] = weight > 1e-6 ? sum / weight : ownColour
                }
            }
        }
        return result
    }

    /// Edge-preserving smoothing over the chameleon's surface (a bilateral filter in 3D):
    /// neighbours within `radius` (character space) count less the further away and the
    /// more different in colour they are.
    static func smooth(_ colours: [Color3?], geometry: CharacterGeometry, radius: Float,
                       colourSpread: Float = 0.18) -> [Color3?] {
        let texels = geometry.validTexels
        var result = colours
        let spatial = 1 / (2 * (radius * 0.5) * (radius * 0.5))
        let tonal = 1 / (2 * colourSpread * colourSpread)
        result.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            Parallel.forEachChunk(count: texels.count, minimumChunk: 512) { range in
                for k in range {
                    let texel = Int(texels[k])
                    guard let centre = colours[texel] else { continue }
                    let p = geometry.texelPositions[texel]
                    let n = geometry.texelNormals[texel]
                    var sum = Color3.zero
                    var weight: Float = 0
                    geometry.grid.forEachTexel(near: p, radius: radius) { other in
                        guard let colour = colours[other], simd_dot(geometry.texelNormals[other], n) > 0.3 else { return }
                        let d2 = simd_distance_squared(geometry.texelPositions[other], p)
                        let c2 = simd_distance_squared(colour, centre)
                        let w = exp(-d2 * spatial - c2 * tonal)
                        sum += colour * w
                        weight += w
                    }
                    if weight > 0 { out.base[texel] = sum / weight }
                }
            }
        }
        return result
    }

    /// The surface just outside a texel: down and away from the chameleon, which is
    /// what's around its bottom edge from any angle.
    static func surfaceColor(beside point: Vec3, normal: Vec3, environment: EnvironmentGeometry) -> Color3? {
        let up = Vec3(0, 1, 0)
        var outward = normal - up * simd_dot(normal, up)
        if simd_length(outward) < 0.15 { outward = Vec3(point.x, 0, point.z) }
        if simd_length(outward) < 1e-4 { outward = Vec3(1, 0, 0) }
        outward = simd_normalize(outward)
        for (away, down) in [(Float(0.5), Float(1)), (1, 0.6), (0.2, 1)] {
            let direction = simd_normalize(outward * away - up * down)
            if let hit = environment.trace(origin: point + outward * 0.01, direction: direction, tMin: 0, tMax: 1.5) {
                return hit.color
            }
        }
        return nil
    }
}
