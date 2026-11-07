//
//  TriangleBVH.swift
//  Bounding-volume hierarchy for fast ray casts against triangle soups.
//
//  Used for: picking where the Pencil touches the character, eyedropping the
//  scanned room, the camo brush ("what's behind this texel?"), and occlusion tests
//  while baking and painting. RealityKit's own collision shapes are convex
//  approximations, so they can't give us exact surface points or barycentrics.
//

import simd

struct RayHit: Sendable {
    /// Distance along the (normalized) ray direction.
    var t: Float
    var triangle: Int
    /// Barycentrics: point = (1 - u - v) * v0 + u * v1 + v * v2.
    var u: Float
    var v: Float
}

struct TriangleBVH: Sendable {

    private struct Node: Sendable {
        var boundsMin: Vec3
        var boundsMax: Vec3
        /// Leaf: first index into `order`. Interior: index of the left child.
        var first: Int32
        /// Leaf: number of triangles (> 0). Interior: 0.
        var count: Int32
        /// Interior: index of the right child.
        var right: Int32
    }

    let v0: [Vec3]
    let v1: [Vec3]
    let v2: [Vec3]
    private var nodes: [Node] = []
    private var order: [Int32] = []

    var triangleCount: Int { v0.count }

    init(v0: [Vec3], v1: [Vec3], v2: [Vec3]) {
        precondition(v0.count == v1.count && v1.count == v2.count, "Mismatched triangle arrays")
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2

        let n = v0.count
        guard n > 0 else { return }

        var centroids = [Vec3](repeating: .zero, count: n)
        var triMin = [Vec3](repeating: .zero, count: n)
        var triMax = [Vec3](repeating: .zero, count: n)
        for i in 0..<n {
            centroids[i] = (v0[i] + v1[i] + v2[i]) / 3
            triMin[i] = simd_min(simd_min(v0[i], v1[i]), v2[i])
            triMax[i] = simd_max(simd_max(v0[i], v1[i]), v2[i])
        }

        order = (0..<n).map { Int32($0) }
        let placeholder = Node(boundsMin: .zero, boundsMax: .zero, first: 0, count: 0, right: -1)
        nodes.reserveCapacity(n / 2 + 1)
        nodes.append(placeholder)

        var stack: [(node: Int, start: Int, end: Int)] = [(0, 0, n)]
        while let (nodeIndex, start, end) = stack.popLast() {
            var bMin = Vec3(repeating: .greatestFiniteMagnitude)
            var bMax = Vec3(repeating: -.greatestFiniteMagnitude)
            var cMin = bMin
            var cMax = bMax
            for k in start..<end {
                let t = Int(order[k])
                bMin = simd_min(bMin, triMin[t])
                bMax = simd_max(bMax, triMax[t])
                cMin = simd_min(cMin, centroids[t])
                cMax = simd_max(cMax, centroids[t])
            }

            let count = end - start
            let extent = cMax - cMin
            let axis = extent.x > extent.y ? (extent.x > extent.z ? 0 : 2) : (extent.y > extent.z ? 1 : 2)

            if count <= 4 || extent[axis] < 1e-7 {
                nodes[nodeIndex] = Node(boundsMin: bMin, boundsMax: bMax,
                                        first: Int32(start), count: Int32(count), right: -1)
                continue
            }

            // Median split along the widest centroid axis.
            order[start..<end].sort { centroids[Int($0)][axis] < centroids[Int($1)][axis] }
            let mid = start + count / 2

            let left = nodes.count
            nodes.append(placeholder)
            let right = nodes.count
            nodes.append(placeholder)
            nodes[nodeIndex] = Node(boundsMin: bMin, boundsMax: bMax,
                                    first: Int32(left), count: 0, right: Int32(right))
            stack.append((right, mid, end))
            stack.append((left, start, mid))
        }
    }

    /// Nearest hit along the ray with `tMin < t < tMax`. Triangles are double-sided.
    func intersect(origin: Vec3, direction: Vec3,
                   tMin: Float = 0, tMax: Float = .greatestFiniteMagnitude) -> RayHit? {
        traverse(origin: origin, direction: direction, tMin: tMin, tMax: tMax, anyHit: false)
    }

    /// True if anything blocks the ray before `tMax`. Cheaper than `intersect`.
    func occluded(origin: Vec3, direction: Vec3, tMin: Float = 0, tMax: Float) -> Bool {
        traverse(origin: origin, direction: direction, tMin: tMin, tMax: tMax, anyHit: true) != nil
    }

    private func traverse(origin o: Vec3, direction rawD: Vec3,
                          tMin: Float, tMax: Float, anyHit: Bool) -> RayHit? {
        guard !nodes.isEmpty else { return nil }

        // Avoid 0 * inf = NaN in the slab test for axis-aligned rays.
        let d = Vec3(abs(rawD.x) < 1e-9 ? 1e-9 : rawD.x,
                     abs(rawD.y) < 1e-9 ? 1e-9 : rawD.y,
                     abs(rawD.z) < 1e-9 ? 1e-9 : rawD.z)
        let inverse = Vec3(1 / d.x, 1 / d.y, 1 / d.z)

        return nodes.withUnsafeBufferPointer { nodeBuffer -> RayHit? in
            order.withUnsafeBufferPointer { orderBuffer -> RayHit? in
                v0.withUnsafeBufferPointer { a -> RayHit? in
                    v1.withUnsafeBufferPointer { b -> RayHit? in
                        v2.withUnsafeBufferPointer { c -> RayHit? in
                            withUnsafeTemporaryAllocation(of: Int32.self, capacity: 64) { stack -> RayHit? in
                                var best: RayHit?
                                var bestT = tMax
                                var sp = 1
                                stack[0] = 0

                                while sp > 0 {
                                    sp -= 1
                                    let node = nodeBuffer[Int(stack[sp])]

                                    // Slab test.
                                    let t1 = (node.boundsMin - o) * inverse
                                    let t2 = (node.boundsMax - o) * inverse
                                    let tNear = simd_reduce_max(simd_min(t1, t2))
                                    let tFar = simd_reduce_min(simd_max(t1, t2))
                                    if tNear > tFar || tFar < tMin || tNear > bestT { continue }

                                    if node.count > 0 {
                                        let first = Int(node.first)
                                        for k in first..<(first + Int(node.count)) {
                                            let tri = Int(orderBuffer[k])
                                            let p0 = a[tri]
                                            let e1 = b[tri] - p0
                                            let e2 = c[tri] - p0
                                            let p = simd_cross(rawD, e2)
                                            let det = simd_dot(e1, p)
                                            if abs(det) < 1e-12 { continue }
                                            let invDet = 1 / det
                                            let s = o - p0
                                            let u = simd_dot(s, p) * invDet
                                            if u < 0 || u > 1 { continue }
                                            let q = simd_cross(s, e1)
                                            let v = simd_dot(rawD, q) * invDet
                                            if v < 0 || u + v > 1 { continue }
                                            let t = simd_dot(e2, q) * invDet
                                            if t > tMin && t < bestT {
                                                bestT = t
                                                best = RayHit(t: t, triangle: tri, u: u, v: v)
                                                if anyHit { return best }
                                            }
                                        }
                                    } else if sp + 2 <= 64 {
                                        stack[sp] = node.right
                                        stack[sp + 1] = node.first
                                        sp += 2
                                    }
                                }
                                return best
                            }
                        }
                    }
                }
            }
        }
    }
}
