//
//  CharacterGeometry.swift
//  Everything needed to render *and paint* the character in one pose:
//
//   - a render mesh whose every quad owns its own square cell in a texture atlas
//   - a texel map: for each atlas pixel, the 3D point and normal it covers
//   - a spatial grid over those texels, so a 3D brush can find the texels
//     inside a sphere without scanning the whole atlas
//   - a BVH for picking where the Pencil ray hits the body
//
//  Because the brush works in 3D space rather than UV space, strokes flow across
//  atlas cell boundaries with no seams.
//

import Foundation
import simd

/// Just the polygonized surface — cheap enough to build for every pose up front
/// (used for the placement ghost).
struct CharacterShape: Sendable {
    let pose: CharacterPose
    let mesh: QuadMesh
    /// Low-detail and a few millimeters fat, for working out which cells of the
    /// occluder grid the character covers (see CharacterMask).
    let mask: MaskMesh
    /// Where its eyes are on this mesh, for painting it in its own colours (ToyPaint).
    var eyes: [CharacterSDF.Eye] = []

    static let cellSize: Float = 0.005
    /// Coarse enough to rasterize every frame — roughly 2 cm across the surface, which
    /// is finer than an occluder cell at arm's length.
    static let maskCellSize: Float = 0.022
    static let maskInflation: Float = 0.008

    /// A mesh for drawing the silhouette: fine enough that the legs, crest and tail
    /// coil survive, and not inflated, because the fattening that keeps the occluder off
    /// the character also welds its legs together.
    static func artMesh(_ pose: CharacterPose) -> QuadMesh {
        var mesh = SurfaceNets.polygonize(CharacterSDF.make(pose), cellSize: 0.0075)
        let lowest = mesh.positions.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
        if lowest.isFinite {
            let lift = Vec3(0, 0.002 - lowest, 0)
            for i in mesh.positions.indices { mesh.positions[i] += lift }
        }
        return mesh
    }

    /// Just the coarse stand-in, without the expensive fine polygonization.
    static func maskOnly(_ pose: CharacterPose) -> MaskMesh {
        let field = CharacterSDF.make(pose)
        var coarse = SurfaceNets.polygonize(InflatedField(base: field, amount: maskInflation),
                                            cellSize: maskCellSize)
        let lowest = coarse.positions.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
        if lowest.isFinite {
            let lift = Vec3(0, 0.002 - lowest, 0)
            for i in coarse.positions.indices { coarse.positions[i] += lift }
        }
        return MaskMesh(quads: coarse)
    }

    static func build(_ pose: CharacterPose) -> CharacterShape {
        let field = CharacterSDF.make(pose)
        var mesh = SurfaceNets.polygonize(field, cellSize: cellSize)
        // Snap the lowest point onto the surface so every pose rests on it exactly.
        let lowest = mesh.positions.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
        var lift = Vec3.zero
        if lowest.isFinite {
            lift = Vec3(0, 0.002 - lowest, 0)
            for i in mesh.positions.indices { mesh.positions[i] += lift }
        }

        var coarse = SurfaceNets.polygonize(InflatedField(base: field, amount: maskInflation),
                                            cellSize: maskCellSize)
        for i in coarse.positions.indices { coarse.positions[i] += lift }
        let eyes = field.eyes.map { CharacterSDF.Eye(centre: $0.centre + lift, radius: $0.radius, look: $0.look) }
        return CharacterShape(pose: pose, mesh: mesh, mask: MaskMesh(quads: coarse), eyes: eyes)
    }
}

/// The same shape grown outward by `amount` — a fatter stand-in for the real surface.
struct InflatedField<Base: SignedDistanceField>: SignedDistanceField {
    let base: Base
    let amount: Float

    func distance(_ p: Vec3) -> Float { base.distance(p) - amount }
    var boundsMin: Vec3 { base.boundsMin - Vec3(repeating: amount * 1.5) }
    var boundsMax: Vec3 { base.boundsMax + Vec3(repeating: amount * 1.5) }
}

struct RenderBuffers: Sendable {
    var positions: [Vec3] = []
    var normals: [Vec3] = []
    var uvs: [Vec2] = []
    var indices: [UInt32] = []
}

/// Atlas v-axis convention. Pixel row 0 is the first row uploaded to the GPU;
/// RealityKit samples with v = 0 at the bottom of the image, so v is flipped.
enum AtlasConvention {
    static let flipV = true

    @inline(__always) static func uv(pixelX: Float, pixelY: Float, width: Int, height: Int) -> Vec2 {
        let u = pixelX / Float(width)
        let v = pixelY / Float(height)
        return Vec2(u, flipV ? 1 - v : v)
    }
}

struct CharacterGeometry: Sendable {
    let pose: CharacterPose
    let render: RenderBuffers
    /// Coarse, slightly fattened stand-in used to keep the occluder off the character.
    let mask: MaskMesh
    let bvh: TriangleBVH

    let atlasWidth: Int
    let atlasHeight: Int
    /// Per atlas pixel. Only meaningful where `texelIsValid`.
    let texelPositions: [Vec3]
    let texelNormals: [Vec3]
    let texelIsValid: [Bool]
    let validTexels: [Int32]
    let grid: TexelGrid

    let boundsMin: Vec3
    let boundsMax: Vec3
    var eyes: [CharacterSDF.Eye] = []

    /// Pixels per atlas cell, including one pixel of padding on each side. Five interior
    /// pixels across a 5 mm quad is ~1 mm per texel — finer than the scan it copies from,
    /// and a third fewer texels for the brush to touch than the 9 it used to be.
    static let cellPixels = 7
    static let cellPadding: Float = 1

    /// - Parameter cellPixels: atlas pixels per quad, padding included. The hand-painted
    ///   chameleon uses the default; the self-camouflaging ones in the "lots of them" game
    ///   use fewer, since nobody paints them by hand and there can be ten at once.
    static func build(from shape: CharacterShape, cellPixels cell: Int = cellPixels) -> CharacterGeometry {
        let mesh = shape.mesh
        let quadCount = mesh.quads.count
        let cellsPerRow = max(1, Int(ceil(Double(quadCount).squareRoot())))
        let rows = max(1, (quadCount + cellsPerRow - 1) / cellsPerRow)
        let pad = cellPadding
        let interior = Float(cell) - 2 * pad
        let width = cellsPerRow * cell
        let height = rows * cell

        // Render buffers: 4 unshared vertices per quad so each gets its own UVs.
        var render = RenderBuffers()
        render.positions.reserveCapacity(quadCount * 4)
        render.normals.reserveCapacity(quadCount * 4)
        render.uvs.reserveCapacity(quadCount * 4)
        render.indices.reserveCapacity(quadCount * 6)

        var triA = [Vec3](), triB = [Vec3](), triC = [Vec3]()
        triA.reserveCapacity(quadCount * 2); triB.reserveCapacity(quadCount * 2); triC.reserveCapacity(quadCount * 2)

        var lo = Vec3(repeating: .greatestFiniteMagnitude)
        var hi = Vec3(repeating: -.greatestFiniteMagnitude)

        for q in 0..<quadCount {
            let ids = mesh.quads[q]
            let p = (0..<4).map { mesh.positions[Int(ids[$0])] }
            let n = (0..<4).map { mesh.normals[Int(ids[$0])] }
            let cellX = Float((q % cellsPerRow) * cell)
            let cellY = Float((q / cellsPerRow) * cell)
            let corners: [(Float, Float)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
            let base = UInt32(render.positions.count)
            for c in 0..<4 {
                render.positions.append(p[c])
                render.normals.append(n[c])
                let px = cellX + pad + corners[c].0 * interior
                let py = cellY + pad + corners[c].1 * interior
                render.uvs.append(AtlasConvention.uv(pixelX: px, pixelY: py, width: width, height: height))
                lo = simd_min(lo, p[c])
                hi = simd_max(hi, p[c])
            }
            render.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            triA.append(p[0]); triB.append(p[1]); triC.append(p[2])
            triA.append(p[0]); triB.append(p[2]); triC.append(p[3])
        }

        // Texel map: the same piecewise-linear (two-triangle) mapping the GPU uses,
        // so a painted texel lands exactly where it renders.
        let texelCount = width * height
        var positions = [Vec3](repeating: .zero, count: texelCount)
        var normals = [Vec3](repeating: [0, 1, 0], count: texelCount)
        var valid = [Bool](repeating: false, count: texelCount)

        positions.withUnsafeMutableBufferPointer { posBuf in
            normals.withUnsafeMutableBufferPointer { nrmBuf in
                valid.withUnsafeMutableBufferPointer { validBuf in
                    let posOut = UnsafeSendablePointer(base: posBuf.baseAddress!)
                    let nrmOut = UnsafeSendablePointer(base: nrmBuf.baseAddress!)
                    let validOut = UnsafeSendablePointer(base: validBuf.baseAddress!)
                    Parallel.forEachChunk(count: quadCount, minimumChunk: 128) { range in
                        for q in range {
                            let ids = mesh.quads[q]
                            let p0 = mesh.positions[Int(ids[0])], p1 = mesh.positions[Int(ids[1])]
                            let p2 = mesh.positions[Int(ids[2])], p3 = mesh.positions[Int(ids[3])]
                            let n0 = mesh.normals[Int(ids[0])], n1 = mesh.normals[Int(ids[1])]
                            let n2 = mesh.normals[Int(ids[2])], n3 = mesh.normals[Int(ids[3])]
                            let cellX = (q % cellsPerRow) * cell
                            let cellY = (q / cellsPerRow) * cell
                            for py in cellY..<(cellY + cell) {
                                let t = clamp01((Float(py) + 0.5 - Float(cellY) - pad) / interior)
                                for px in cellX..<(cellX + cell) {
                                    let s = clamp01((Float(px) + 0.5 - Float(cellX) - pad) / interior)
                                    let point: Vec3
                                    let normal: Vec3
                                    if s >= t {
                                        point = p0 + s * (p1 - p0) + t * (p2 - p1)
                                        normal = n0 + s * (n1 - n0) + t * (n2 - n1)
                                    } else {
                                        point = p0 + t * (p3 - p0) + s * (p2 - p3)
                                        normal = n0 + t * (n3 - n0) + s * (n2 - n3)
                                    }
                                    let index = py * width + px
                                    posOut.base[index] = point
                                    let len = simd_length(normal)
                                    nrmOut.base[index] = len > 1e-6 ? normal / len : [0, 1, 0]
                                    validOut.base[index] = true
                                }
                            }
                        }
                    }
                }
            }
        }

        var validTexels = [Int32]()
        validTexels.reserveCapacity(quadCount * cell * cell)
        for i in 0..<texelCount where valid[i] { validTexels.append(Int32(i)) }

        let grid = TexelGrid(positions: positions, texels: validTexels,
                             boundsMin: lo, boundsMax: hi, cellSize: 0.01)

        return CharacterGeometry(pose: shape.pose, render: render, mask: shape.mask,
                                 bvh: TriangleBVH(v0: triA, v1: triB, v2: triC),
                                 atlasWidth: width, atlasHeight: height,
                                 texelPositions: positions, texelNormals: normals,
                                 texelIsValid: valid, validTexels: validTexels,
                                 grid: grid, boundsMin: lo, boundsMax: hi, eyes: shape.eyes)
    }
}

// MARK: - Spatial grid

/// Uniform 3D grid in compressed-row form: texels bucketed by the cell their
/// 3D position falls in.
struct TexelGrid: Sendable {
    let origin: Vec3
    let cellSize: Float
    let nx: Int, ny: Int, nz: Int
    private let cellStart: [Int32]
    private let entries: [Int32]

    init(positions: [Vec3], texels: [Int32], boundsMin: Vec3, boundsMax: Vec3, cellSize: Float) {
        self.cellSize = cellSize
        origin = boundsMin - Vec3(repeating: cellSize)
        let extent = boundsMax - boundsMin + Vec3(repeating: cellSize * 2)
        nx = max(1, Int(ceil(extent.x / cellSize)) + 1)
        ny = max(1, Int(ceil(extent.y / cellSize)) + 1)
        nz = max(1, Int(ceil(extent.z / cellSize)) + 1)

        let cellCount = nx * ny * nz
        var counts = [Int32](repeating: 0, count: cellCount + 1)
        var cellOf = [Int32](repeating: 0, count: texels.count)
        for (k, texel) in texels.enumerated() {
            let c = TexelGrid.cell(of: positions[Int(texel)], origin: origin, cellSize: cellSize, nx: nx, ny: ny, nz: nz)
            cellOf[k] = Int32(c)
            counts[c + 1] += 1
        }
        for c in 0..<cellCount { counts[c + 1] += counts[c] }
        var cursor = counts
        var entries = [Int32](repeating: 0, count: texels.count)
        for (k, texel) in texels.enumerated() {
            let c = Int(cellOf[k])
            entries[Int(cursor[c])] = texel
            cursor[c] += 1
        }
        cellStart = counts
        self.entries = entries
    }

    @inline(__always) private static func cell(of p: Vec3, origin: Vec3, cellSize: Float, nx: Int, ny: Int, nz: Int) -> Int {
        let g = (p - origin) / cellSize
        let i = min(max(Int(g.x), 0), nx - 1)
        let j = min(max(Int(g.y), 0), ny - 1)
        let k = min(max(Int(g.z), 0), nz - 1)
        return i + nx * (j + ny * k)
    }

    /// Calls `body` for every texel whose grid cell overlaps the sphere's bounding box.
    /// Callers still need to do the exact distance test.
    func forEachTexel(near center: Vec3, radius: Float, _ body: (Int) -> Void) {
        let lo = (center - Vec3(repeating: radius) - origin) / cellSize
        let hi = (center + Vec3(repeating: radius) - origin) / cellSize
        let i0 = max(Int(floor(lo.x)), 0), i1 = min(Int(floor(hi.x)), nx - 1)
        let j0 = max(Int(floor(lo.y)), 0), j1 = min(Int(floor(hi.y)), ny - 1)
        let k0 = max(Int(floor(lo.z)), 0), k1 = min(Int(floor(hi.z)), nz - 1)
        guard i0 <= i1, j0 <= j1, k0 <= k1 else { return }
        cellStart.withUnsafeBufferPointer { starts in
            entries.withUnsafeBufferPointer { list in
                for k in k0...k1 {
                    for j in j0...j1 {
                        for i in i0...i1 {
                            let c = i + nx * (j + ny * k)
                            for e in Int(starts[c])..<Int(starts[c + 1]) {
                                body(Int(list[e]))
                            }
                        }
                    }
                }
            }
        }
    }
}
