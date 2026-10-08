//
//  EnvironmentGeometry.swift
//  The extracted chunk of the real room around the hiding spot: LiDAR triangles
//  (in hide-anchor space) plus a texture atlas holding their color.
//
//  LiDAR meshes have no UVs, so every triangle gets its own little square cell in
//  the atlas, sized in proportion to the triangle so texel density is roughly
//  uniform in meters. The triangle occupies the lower-left half of its cell; the
//  rest is filled with clamped edge colors so bilinear filtering never bleeds in
//  a neighbor's color.
//

import Foundation
import simd

struct TriangleAtlas: Sendable {
    let width: Int
    let height: Int
    let cellX: [Int32]
    let cellY: [Int32]
    let cellSize: [Int32]

    static let padding: Float = 1

    /// Continuous pixel coordinates (texel centers at +0.5) for barycentrics (s, t)
    /// where point = (1 - s - t) * v0 + s * v1 + t * v2.
    @inline(__always) func pixel(triangle i: Int, s: Float, t: Float) -> (x: Float, y: Float) {
        let interior = Float(cellSize[i]) - 2 * TriangleAtlas.padding
        return (Float(cellX[i]) + TriangleAtlas.padding + s * interior,
                Float(cellY[i]) + TriangleAtlas.padding + t * interior)
    }

    /// Shelf-packs triangle cells, lowering texel density until everything fits.
    static func pack(v0: [Vec3], v1: [Vec3], v2: [Vec3],
                     texelsPerMeter: Float, maxDimension: Int) -> TriangleAtlas {
        let n = v0.count
        var longest = [Float](repeating: 0, count: n)
        var sumSquares: Float = 0
        for i in 0..<n {
            let e = max(simd_length(v1[i] - v0[i]), simd_length(v2[i] - v0[i]), simd_length(v2[i] - v1[i]))
            longest[i] = e
            sumSquares += e * e
        }

        var density = texelsPerMeter
        // First guess so the total cell area fits comfortably.
        let budget = Float(maxDimension * maxDimension) * 0.8
        if sumSquares * density * density > budget {
            density = (budget / max(sumSquares, 1e-6)).squareRoot()
        }

        while true {
            var sizes = [Int32](repeating: 4, count: n)
            var area = 0
            for i in 0..<n {
                let s = min(max(Int(ceil(longest[i] * density)) + 2, 4), 96)
                sizes[i] = Int32(s)
                area += s * s
            }
            let width = min(maxDimension, max(64, Int(ceil(Double(area).squareRoot() * 1.08))))
            let sorted = (0..<n).sorted { sizes[$0] > sizes[$1] }

            var cellX = [Int32](repeating: 0, count: n)
            var cellY = [Int32](repeating: 0, count: n)
            var x = 0, y = 0, rowHeight = 0
            for i in sorted {
                let s = Int(sizes[i])
                if x + s > width {
                    y += rowHeight
                    x = 0
                    rowHeight = 0
                }
                cellX[i] = Int32(x)
                cellY[i] = Int32(y)
                x += s
                rowHeight = max(rowHeight, s)
            }
            let height = y + rowHeight

            if height <= maxDimension || density < 20 {
                return TriangleAtlas(width: width, height: max(height, 4),
                                     cellX: cellX, cellY: cellY, cellSize: sizes)
            }
            density *= 0.9
        }
    }
}

struct EnvironmentGeometry: Sendable {
    let bvh: TriangleBVH
    let faceNormals: [Vec3]
    let atlas: TriangleAtlas
    /// RGBA8, sRGB, `atlas.width * atlas.height * 4`.
    var pixels: [UInt8]

    var triangleCount: Int { bvh.triangleCount }

    init(v0: [Vec3], v1: [Vec3], v2: [Vec3], texelsPerMeter: Float = 400, maxDimension: Int = 4096) {
        bvh = TriangleBVH(v0: v0, v1: v1, v2: v2)
        faceNormals = (0..<v0.count).map { i in
            let n = simd_cross(v1[i] - v0[i], v2[i] - v0[i])
            let len = simd_length(n)
            return len > 1e-10 ? n / len : [0, 1, 0]
        }
        atlas = TriangleAtlas.pack(v0: v0, v1: v1, v2: v2,
                                   texelsPerMeter: texelsPerMeter, maxDimension: maxDimension)
        pixels = [UInt8](repeating: 128, count: atlas.width * atlas.height * 4)
    }

    // MARK: Sampling

    /// Bilinear color at a point given by barycentrics on a triangle (as returned by a `RayHit`).
    func color(triangle: Int, u: Float, v: Float) -> Color3 {
        let (px, py) = atlas.pixel(triangle: triangle, s: u, t: v)
        return pixels.withUnsafeBufferPointer { buffer in
            EnvironmentGeometry.bilinear(buffer, width: atlas.width, height: atlas.height, x: px - 0.5, y: py - 0.5)
        }
    }

    /// Nearest environment surface along a ray, with its color.
    func trace(origin: Vec3, direction: Vec3, tMin: Float = 0,
               tMax: Float = .greatestFiniteMagnitude) -> (hit: RayHit, color: Color3)? {
        guard let hit = bvh.intersect(origin: origin, direction: direction, tMin: tMin, tMax: tMax) else { return nil }
        return (hit, color(triangle: hit.triangle, u: hit.u, v: hit.v))
    }

    @inline(__always) static func bilinear(_ buffer: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                                           x: Float, y: Float) -> Color3 {
        let fx = min(max(x, 0), Float(width - 1))
        let fy = min(max(y, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let ax = fx - Float(x0), ay = fy - Float(y0)
        @inline(__always) func at(_ px: Int, _ py: Int) -> Color3 {
            let i = (py * width + px) * 4
            return Color3(Float(buffer[i]), Float(buffer[i + 1]), Float(buffer[i + 2])) / 255
        }
        let top = at(x0, y0) * (1 - ax) + at(x1, y0) * ax
        let bottom = at(x0, y1) * (1 - ax) + at(x1, y1) * ax
        return top * (1 - ay) + bottom * ay
    }

    // MARK: Texel iteration

    /// Visits every pixel of a triangle's cell with the 3D point it represents.
    /// Pixels outside the triangle get clamped (edge) positions, which pads the cell.
    @inline(__always) func forEachTexel(ofTriangle i: Int, _ body: (_ x: Int, _ y: Int, _ point: Vec3) -> Void) {
        let a = bvh.v0[i], b = bvh.v1[i], c = bvh.v2[i]
        let x0 = Int(atlas.cellX[i]), y0 = Int(atlas.cellY[i]), size = Int(atlas.cellSize[i])
        let interior = Float(size) - 2 * TriangleAtlas.padding
        for py in y0..<(y0 + size) {
            let tRaw = max(0, (Float(py) + 0.5 - Float(y0) - TriangleAtlas.padding) / interior)
            for px in x0..<(x0 + size) {
                var s = max(0, (Float(px) + 0.5 - Float(x0) - TriangleAtlas.padding) / interior)
                var t = tRaw
                let sum = s + t
                if sum > 1 {
                    s /= sum
                    t /= sum
                }
                body(px, py, a + s * (b - a) + t * (c - a))
            }
        }
    }

    /// Fills the atlas from a color function of (anchor-space point, face normal).
    mutating func paint(_ colorAt: @Sendable (Vec3, Vec3) -> Color3) {
        let width = atlas.width
        let snapshot = self
        pixels.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            Parallel.forEachChunk(count: snapshot.triangleCount) { range in
                for tri in range {
                    let normal = snapshot.faceNormals[tri]
                    snapshot.forEachTexel(ofTriangle: tri) { x, y, point in
                        let (r, g, b) = packRGBA(colorAt(point, normal))
                        let i = (y * width + x) * 4
                        out.base[i] = r; out.base[i + 1] = g; out.base[i + 2] = b; out.base[i + 3] = 255
                    }
                }
            }
        }
    }

    func renderBuffers() -> RenderBuffers {
        var out = RenderBuffers()
        let n = triangleCount
        out.positions.reserveCapacity(n * 3)
        out.normals.reserveCapacity(n * 3)
        out.uvs.reserveCapacity(n * 3)
        out.indices.reserveCapacity(n * 3)
        let corners: [(Float, Float)] = [(0, 0), (1, 0), (0, 1)]
        for i in 0..<n {
            let verts = [bvh.v0[i], bvh.v1[i], bvh.v2[i]]
            for c in 0..<3 {
                let (px, py) = atlas.pixel(triangle: i, s: corners[c].0, t: corners[c].1)
                out.indices.append(UInt32(out.positions.count))
                out.positions.append(verts[c])
                out.normals.append(faceNormals[i])
                out.uvs.append(AtlasConvention.uv(pixelX: px, pixelY: py, width: atlas.width, height: atlas.height))
            }
        }
        return out
    }
}
