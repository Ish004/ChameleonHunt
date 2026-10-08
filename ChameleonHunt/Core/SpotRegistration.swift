//
//  SpotRegistration.swift
//  Snaps a roughly-placed hiding spot back onto the geometry it was scanned against.
//
//  Getting back to a hiding spot by camera relocalization means standing where you
//  stood when you scanned, which nobody does — you sit down to paint, then come back
//  from wherever you are. This instead matches the *shape* of the room: take the
//  surfaces captured in the scan, take what LiDAR sees now, and find the rigid
//  transform that lines them up (iterative closest point).
//
//  Only yaw and position are solved for. Both scans share ARKit's gravity, so tilt is
//  already correct, and holding it fixed makes the fit far more stable than solving
//  all six degrees of freedom from noisy LiDAR.
//

import Foundation
import simd

enum SpotRegistration {

    struct Result: Sendable {
        var transform: simd_float4x4
        /// Average distance between matched points, in meters.
        var meanError: Float
        /// Fraction of scan points that found a match.
        var inlierRatio: Float
        var yawCorrection: Float
        var moved: Float

        var isGood: Bool { meanError < 0.045 && inlierRatio > 0.45 }
    }

    /// Nearest-neighbour lookup over the live points, bucketed by voxel.
    struct PointGrid: Sendable {
        private let cell: Float
        private let origin: Vec3
        private let dimensions: SIMD3<Int>
        private let starts: [Int32]
        private let entries: [Int32]
        let points: [Vec3]

        init(points: [Vec3], cell: Float = 0.06) {
            self.points = points
            self.cell = cell
            guard !points.isEmpty else {
                origin = .zero; dimensions = .zero; starts = [0]; entries = []
                return
            }
            var lo = Vec3(repeating: .greatestFiniteMagnitude)
            var hi = Vec3(repeating: -.greatestFiniteMagnitude)
            for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            origin = lo - Vec3(repeating: cell)
            let span = (hi - lo) / cell
            dimensions = SIMD3(max(Int(span.x) + 3, 1), max(Int(span.y) + 3, 1), max(Int(span.z) + 3, 1))

            let cellCount = dimensions.x * dimensions.y * dimensions.z
            var counts = [Int32](repeating: 0, count: cellCount + 1)
            var cellOf = [Int32](repeating: 0, count: points.count)
            for (i, p) in points.enumerated() {
                let index = Self.index(of: p, origin: origin, cell: cell, dimensions: dimensions)
                cellOf[i] = Int32(index)
                counts[index + 1] += 1
            }
            for c in 0..<cellCount { counts[c + 1] += counts[c] }
            var cursor = counts
            var entries = [Int32](repeating: 0, count: points.count)
            for (i, _) in points.enumerated() {
                let c = Int(cellOf[i])
                entries[Int(cursor[c])] = Int32(i)
                cursor[c] += 1
            }
            starts = counts
            self.entries = entries
        }

        private static func index(of p: Vec3, origin: Vec3, cell: Float, dimensions: SIMD3<Int>) -> Int {
            let g = (p - origin) / cell
            let x = min(max(Int(g.x), 0), dimensions.x - 1)
            let y = min(max(Int(g.y), 0), dimensions.y - 1)
            let z = min(max(Int(g.z), 0), dimensions.z - 1)
            return x + dimensions.x * (y + dimensions.y * z)
        }

        /// Closest point within `radius`, or nil.
        func nearest(to p: Vec3, within radius: Float) -> Vec3? {
            guard !points.isEmpty else { return nil }
            let g = (p - origin) / cell
            let reach = Int(ceil(radius / cell))
            let cx = Int(g.x), cy = Int(g.y), cz = Int(g.z)
            var best: Vec3?
            var bestDistance = radius * radius

            for z in (cz - reach)...(cz + reach) {
                guard z >= 0, z < dimensions.z else { continue }
                for y in (cy - reach)...(cy + reach) {
                    guard y >= 0, y < dimensions.y else { continue }
                    for x in (cx - reach)...(cx + reach) {
                        guard x >= 0, x < dimensions.x else { continue }
                        let c = x + dimensions.x * (y + dimensions.y * z)
                        for e in Int(starts[c])..<Int(starts[c + 1]) {
                            let candidate = points[Int(entries[e])]
                            let d = simd_distance_squared(candidate, p)
                            if d < bestDistance {
                                bestDistance = d
                                best = candidate
                            }
                        }
                    }
                }
            }
            return best
        }
    }

    /// Aligns `scanPoints` (in hide-anchor space) onto `live` (world space).
    ///
    /// The position is only allowed to move within `maxTranslation` of the guess. Large
    /// flat surfaces — a floor, a wall — fit equally well anywhere along themselves, so
    /// an unconstrained fit happily slides the spot along the wall it was scanned
    /// against. The person placing the character supplies the position; this recovers
    /// the facing they can't judge by eye, and trims a few centimetres.
    /// - Parameters:
    ///   - initial: the current guess for anchor → world.
    ///   - up: world up; rotation is solved around this axis only.
    static func refine(scanPoints: [Vec3], live: PointGrid, initial: simd_float4x4, up: Vec3 = [0, 1, 0],
                       iterations: Int = 24, maxCorrespondence: Float = 0.18,
                       maxTranslation: Float = 0.08) -> Result? {
        guard scanPoints.count >= 12, live.points.count >= 12 else { return nil }
        let axis = simd_normalize(up)
        var transform = initial
        var meanError: Float = .greatestFiniteMagnitude
        var inlierRatio: Float = 0

        var radius = maxCorrespondence
        for iteration in 0..<iterations {
            var sources: [Vec3] = []
            var targets: [Vec3] = []
            sources.reserveCapacity(scanPoints.count)
            targets.reserveCapacity(scanPoints.count)
            var errorSum: Float = 0

            for point in scanPoints {
                let world = transform.transformPoint(point)
                guard let match = live.nearest(to: world, within: radius) else { continue }
                sources.append(world)
                targets.append(match)
                errorSum += simd_distance(world, match)
            }

            inlierRatio = Float(sources.count) / Float(scanPoints.count)
            guard sources.count >= 8 else { return nil }
            meanError = errorSum / Float(sources.count)

            // Best yaw + translation for these pairs.
            let sourceMean = sources.reduce(Vec3.zero, +) / Float(sources.count)
            let targetMean = targets.reduce(Vec3.zero, +) / Float(targets.count)
            var sinSum: Float = 0
            var cosSum: Float = 0
            for (s, t) in zip(sources, targets) {
                let a = perpendicularComponent(s - sourceMean, axis: axis)
                let b = perpendicularComponent(t - targetMean, axis: axis)
                cosSum += simd_dot(a, b)
                sinSum += simd_dot(simd_cross(a, b), axis)
            }
            let angle = atan2(sinSum, cosSum)
            let rotation = simd_float4x4(simd_quatf(angle: angle, axis: axis))

            // Rotate about the source centroid, then line the centroids up.
            let step = simd_float4x4(translation: targetMean) * rotation * simd_float4x4(translation: -sourceMean)
            transform = step * transform

            // Keep the fit anchored near where the player put it.
            var offset = transform.translation - initial.translation
            if simd_length(offset) > maxTranslation {
                offset = simd_normalize(offset) * maxTranslation
                transform.columns.3 = SIMD4<Float>(initial.translation + offset, 1)
            }

            // Tighten the search as the fit improves.
            if iteration > 2 { radius = max(0.05, radius * 0.85) }
        }

        let delta = initial.inverse * transform
        let yaw = atan2(delta.columns.0.z, delta.columns.0.x)
        return Result(transform: transform, meanError: meanError, inlierRatio: inlierRatio,
                      yawCorrection: yaw, moved: simd_distance(transform.translation, initial.translation))
    }

    /// Picks scan points spread across surface orientations, so a small object's edges
    /// count for as much as the large flat floor they sit on and the fit has something
    /// to lock onto.
    static func samplePoints(from environment: EnvironmentGeometry, radius: Float = 1.0,
                             maxPoints: Int = 400) -> [Vec3] {
        var buckets: [Int: [Vec3]] = [:]
        for triangle in 0..<environment.triangleCount {
            let centroid = (environment.bvh.v0[triangle] + environment.bvh.v1[triangle]
                            + environment.bvh.v2[triangle]) / 3
            guard simd_length(centroid) < radius else { continue }
            let n = environment.faceNormals[triangle]
            // Quantized normal direction.
            let key = Int((n.x * 2.49).rounded()) &* 100 &+ Int((n.y * 2.49).rounded()) &* 10 &+ Int((n.z * 2.49).rounded())
            buckets[key, default: []].append(centroid)
        }
        guard !buckets.isEmpty else { return [] }

        let perBucket = max(8, maxPoints / buckets.count)
        var points: [Vec3] = []
        for (_, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            let step = max(1, bucket.count / perBucket)
            for i in stride(from: 0, to: bucket.count, by: step) { points.append(bucket[i]) }
        }
        return points
    }

    @inline(__always) private static func perpendicularComponent(_ v: Vec3, axis: Vec3) -> Vec3 {
        v - axis * simd_dot(v, axis)
    }
}
