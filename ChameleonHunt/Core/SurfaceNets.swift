//
//  SurfaceNets.swift
//  Turns a signed distance field into a smooth, watertight quad mesh.
//
//  Surface nets place one vertex inside every grid cell the surface passes
//  through (at the average of the edge crossings), then join the four cells
//  around every sign-changing grid edge into a quad. Unlike marching cubes it
//  needs no lookup tables and it outputs quads, which map 1:1 onto square
//  texture-atlas cells with no wasted space.
//

import Foundation
import simd

protocol SignedDistanceField: Sendable {
    /// Negative inside, positive outside, in meters.
    func distance(_ p: Vec3) -> Float
    var boundsMin: Vec3 { get }
    var boundsMax: Vec3 { get }
}

struct QuadMesh: Sendable {
    var positions: [Vec3] = []
    var normals: [Vec3] = []
    /// Vertex indices, counter-clockwise when viewed from outside.
    var quads: [SIMD4<Int32>] = []
}

enum SurfaceNets {

    private static let cornerOffsets: [Vec3] = [
        [0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0],
        [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]
    ]

    private static let cellEdges: [(Int, Int)] = [
        (0, 1), (2, 3), (4, 5), (6, 7),   // along x
        (0, 2), (1, 3), (4, 6), (5, 7),   // along y
        (0, 4), (1, 5), (2, 6), (3, 7)    // along z
    ]

    static func polygonize<Field: SignedDistanceField>(_ field: Field, cellSize: Float) -> QuadMesh {
        let padding = cellSize * 2
        let lo = field.boundsMin - Vec3(repeating: padding)
        let hi = field.boundsMax + Vec3(repeating: padding)
        let nx = Int(ceil((hi.x - lo.x) / cellSize)) + 1
        let ny = Int(ceil((hi.y - lo.y) / cellSize)) + 1
        let nz = Int(ceil((hi.z - lo.z) / cellSize)) + 1

        @inline(__always) func pointIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }

        // 1. Sample the field at every grid point (parallel over z slices).
        var values = [Float](repeating: 0, count: nx * ny * nz)
        values.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: nz) { k in
                for j in 0..<ny {
                    for i in 0..<nx {
                        let p = lo + Vec3(Float(i), Float(j), Float(k)) * cellSize
                        out.base[i + nx * (j + ny * k)] = field.distance(p)
                    }
                }
            }
        }

        // 2. One vertex per surface-crossing cell.
        let cx = nx - 1, cy = ny - 1, cz = nz - 1
        @inline(__always) func cellIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { i + cx * (j + cy * k) }

        var cellVertex = [Int32](repeating: -1, count: cx * cy * cz)
        var mesh = QuadMesh()

        for k in 0..<cz {
            for j in 0..<cy {
                for i in 0..<cx {
                    var corner = SIMD8<Float>()
                    var inside = 0
                    for c in 0..<8 {
                        let o = cornerOffsets[c]
                        let value = values[pointIndex(i + Int(o.x), j + Int(o.y), k + Int(o.z))]
                        corner[c] = value
                        if value < 0 { inside += 1 }
                    }
                    if inside == 0 || inside == 8 { continue }

                    var sum = Vec3.zero
                    var crossings: Float = 0
                    for (a, b) in cellEdges {
                        let va = corner[a], vb = corner[b]
                        if (va < 0) == (vb < 0) { continue }
                        let t = va / (va - vb)
                        sum += cornerOffsets[a] + (cornerOffsets[b] - cornerOffsets[a]) * t
                        crossings += 1
                    }
                    let local = sum / crossings
                    let position = lo + (Vec3(Float(i), Float(j), Float(k)) + local) * cellSize

                    cellVertex[cellIndex(i, j, k)] = Int32(mesh.positions.count)
                    mesh.positions.append(position)
                    mesh.normals.append(gradient(field, at: position, h: cellSize * 0.5))
                }
            }
        }

        // 3. A quad around every sign-changing grid edge.
        func emit(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            let ids = [cellVertex[a], cellVertex[b], cellVertex[c], cellVertex[d]]
            if ids.contains(-1) { return }
            let p = ids.map { mesh.positions[Int($0)] }
            let faceNormal = simd_cross(p[2] - p[0], p[3] - p[1])
            let reference = ids.reduce(Vec3.zero) { $0 + mesh.normals[Int($1)] }
            if simd_dot(faceNormal, reference) >= 0 {
                mesh.quads.append(SIMD4(ids[0], ids[1], ids[2], ids[3]))
            } else {
                mesh.quads.append(SIMD4(ids[0], ids[3], ids[2], ids[1]))
            }
        }

        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let here = values[pointIndex(i, j, k)] < 0
                    // x-edge
                    if i < nx - 1, j >= 1, j < ny - 1, k >= 1, k < nz - 1,
                       here != (values[pointIndex(i + 1, j, k)] < 0) {
                        emit(cellIndex(i, j - 1, k - 1), cellIndex(i, j, k - 1),
                             cellIndex(i, j, k), cellIndex(i, j - 1, k))
                    }
                    // y-edge
                    if j < ny - 1, i >= 1, i < nx - 1, k >= 1, k < nz - 1,
                       here != (values[pointIndex(i, j + 1, k)] < 0) {
                        emit(cellIndex(i - 1, j, k - 1), cellIndex(i, j, k - 1),
                             cellIndex(i, j, k), cellIndex(i - 1, j, k))
                    }
                    // z-edge
                    if k < nz - 1, i >= 1, i < nx - 1, j >= 1, j < ny - 1,
                       here != (values[pointIndex(i, j, k + 1)] < 0) {
                        emit(cellIndex(i - 1, j - 1, k), cellIndex(i, j - 1, k),
                             cellIndex(i, j, k), cellIndex(i - 1, j, k))
                    }
                }
            }
        }

        return mesh
    }

    private static func gradient<Field: SignedDistanceField>(_ field: Field, at p: Vec3, h: Float) -> Vec3 {
        let g = Vec3(field.distance(p + [h, 0, 0]) - field.distance(p - [h, 0, 0]),
                     field.distance(p + [0, h, 0]) - field.distance(p - [0, h, 0]),
                     field.distance(p + [0, 0, h]) - field.distance(p - [0, 0, h]))
        let len = simd_length(g)
        return len > 1e-8 ? g / len : [0, 1, 0]
    }
}
