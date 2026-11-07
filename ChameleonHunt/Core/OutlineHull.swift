//
//  OutlineHull.swift
//  The shape of a chameleon's rim: its own surface, pushed out a little all round.
//
//  A chameleon that's out in the open is drawn with a rim (ChameleonActor): a copy of its
//  shape made slightly bigger and drawn inside out, so the chameleon itself hides all of
//  it but what shows past its own edge, from wherever it's looked at.
//
//  Pushing every point straight out along its normal makes that copy wherever the surface
//  bulges. In a crease tighter than the push (behind an eye, where a leg meets the body,
//  the dimple of a pupil) the pushed surface crosses itself, and the triangles there end
//  up facing the wrong way. Drawn inside out, those show as flecks of the rim's colour in
//  front of the chameleon. So the points round a triangle that has turned are pushed
//  less, and less again, until none has.
//
//  A dent does the same thing without anything turning: seen at a slant, its near wall
//  faces away, and the copy of that wall stands in front of the chameleon. The one dent
//  that matters is the socket of each pupil, right where everyone looks; the rim bridges
//  those, following the ball of the eye across instead of dipping in.
//

import Foundation
import simd

enum OutlineHull {

    /// A triangle counts as turned once it faces further than this from where it faced
    /// (the cosine of about 70°): short of inside out, so the hull stops well before.
    static let turnLimit: Float = 0.34

    /// A dent to bridge: a ball (an eye) with a hollow in it where it looks (the pupil).
    struct Socket {
        let centre: Vec3
        let radius: Float
        let look: Vec3
        /// How far round from where it looks the hollow can reach (the cosine of ~35°).
        static let reach: Float = 0.82
    }

    /// `buffers` with every point moved out along its normal by up to `width` (in the
    /// shape's own units), and less in creases. Points in the same place move together,
    /// so the surface stays closed. Texture coordinates are dropped: a rim is one colour.
    /// - Parameter sockets: dents the hull goes straight across (the chameleon's pupils).
    static func expand(_ buffers: RenderBuffers, by width: Float, bridging sockets: [Socket] = []) -> RenderBuffers {
        let count = min(buffers.positions.count, buffers.normals.count)
        var hull = buffers
        hull.uvs = []
        guard count > 0, width > 0 else { return hull }

        // The corners of neighbouring quads are separate points in the same place (each
        // quad has its own patch of paint): one push for each place.
        var places: [Vec3: Int32] = [:]
        places.reserveCapacity(count / 3)
        var placeOf = [Int32](repeating: 0, count: count)
        // Where each point starts from and which way it goes: its own place and normal,
        // or, down in a socket, the ball's surface above it and straight out from the ball.
        var starts = [Vec3](repeating: .zero, count: count)
        var directions = [Vec3](repeating: .zero, count: count)
        for i in 0..<count {
            let position = buffers.positions[i]
            if let known = places[position] {
                placeOf[i] = known
            } else {
                placeOf[i] = Int32(places.count)
                places[position] = Int32(places.count)
            }
            starts[i] = position
            let normal = buffers.normals[i]
            let length = simd_length(normal)
            if length > 1e-6 { directions[i] = normal / length }
            for socket in sockets {
                let offset = position - socket.centre
                let distance = simd_length(offset)
                guard distance > 1e-6, distance < socket.radius,
                      simd_dot(offset / distance, socket.look) > Socket.reach else { continue }
                starts[i] = socket.centre + offset / distance * socket.radius
                directions[i] = offset / distance
            }
        }
        var push = [Float](repeating: width, count: places.count)
        func moved(_ i: Int) -> Vec3 { starts[i] + directions[i] * push[Int(placeOf[i])] }

        let triangles = stride(from: 0, to: buffers.indices.count - 2, by: 3)
        for _ in 0..<14 {
            var ease = [Bool](repeating: false, count: push.count)
            var turned = false
            for t in triangles {
                let a = Int(buffers.indices[t]), b = Int(buffers.indices[t + 1]), c = Int(buffers.indices[t + 2])
                guard a < count, b < count, c < count else { continue }
                let before = simd_cross(starts[b] - starts[a], starts[c] - starts[a])
                let pa = moved(a)
                let after = simd_cross(moved(b) - pa, moved(c) - pa)
                let scale = simd_length(before) * simd_length(after)
                // A sliver with no area faces nowhere; if the push made one, ease that too.
                guard simd_length(before) > 1e-12 else { continue }
                if scale <= 1e-20 || simd_dot(before, after) < turnLimit * scale {
                    turned = true
                    ease[Int(placeOf[a])] = true; ease[Int(placeOf[b])] = true; ease[Int(placeOf[c])] = true
                }
            }
            guard turned else { break }
            for i in push.indices where ease[i] { push[i] *= 0.7 }
        }

        for i in 0..<count { hull.positions[i] = moved(i) }
        return hull
    }
}
