//
//  AimStabilizer.swift
//  Keeps the chameleon you're placing still while you aim.
//
//  The placing preview used to sit exactly where the centre of the screen hit the room,
//  recomputed every frame. The LiDAR mesh is rough by a centimetre or so and its
//  triangles tilt a few degrees this way and that, a hand is never perfectly still, and
//  the preview also turned to face the camera every frame — so it shivered, wobbled and
//  swivelled, and "Hide here" put it down wherever the last noisy reading happened to be.
//
//  So the aim is filtered the way a steady hand would want:
//   - Hold. Small wobbles (under about a centimetre, a few degrees) change nothing.
//   - Follow. A real move is followed quickly and smoothly, without the lag of a heavy
//     filter.
//   - Jump. Aiming at a different surface (far away, or a floor to a wall) goes straight
//     there.
//   - Level. Floors and tables are level; a surface within a few degrees of level is
//     treated as exactly level, so the chameleon never rocks on the mesh's noise.
//   - Facing. It turns to face you only when you've walked a good way round, and then
//     eases round, instead of swivelling with every step.
//

import simd

struct AimStabilizer: Sendable {

    struct Settings: Sendable {
        /// Wobble smaller than this doesn't move it.
        var holdDistance: Float = 0.012
        /// Tilt smaller than this doesn't tilt it (radians).
        var holdAngle: Float = 6 * .pi / 180
        /// A move bigger than this is a new spot: go straight there.
        var jumpDistance: Float = 0.25
        /// How quickly a real move is followed.
        var followTime: Float = 0.06
        /// Within this of level counts as level (radians).
        var levelAngle: Float = 12 * .pi / 180
        /// Only turn to face the viewer once they're this far round (radians)…
        var facingHoldAngle: Float = 25 * .pi / 180
        /// …and then turn this smoothly.
        var facingTime: Float = 0.3
    }

    struct Aim: Sendable, Equatable {
        var position: Vec3
        var normal: Vec3
        /// Which way the chameleon faces, along the surface.
        var facing: Vec3
    }

    private(set) var aim: Aim?
    private var kind: SurfaceKind?
    private var lastTime: Double?
    private var turning = false
    private let settings: Settings

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    mutating func reset() {
        aim = nil
        kind = nil
        lastTime = nil
        turning = false
    }

    /// Feeds in this frame's raw hit; returns where the chameleon should be.
    mutating func update(position: Vec3, normal rawNormal: Vec3, kind newKind: SurfaceKind,
                         viewer: Vec3, time: Double) -> Aim {
        let normal = level(simd_normalize(rawNormal), kind: newKind)
        let wantedFacing = Self.facing(towards: viewer - position, normal: normal)
        let dt = Float(max(0, min(time - (lastTime ?? time), 0.25)))
        lastTime = time

        guard var current = aim, kind == newKind,
              simd_distance(current.position, position) < settings.jumpDistance else {
            // First sight, a new kind of surface, or a jump: go straight there.
            kind = newKind
            let fresh = Aim(position: position, normal: normal, facing: wantedFacing)
            aim = fresh
            turning = false
            return fresh
        }

        let follow = 1 - exp(-dt / settings.followTime)

        let offset = position - current.position
        let distance = simd_length(offset)
        if distance > settings.holdDistance {
            // Follow, but only the part beyond the hold, so it glides rather than stepping.
            let target = current.position + offset * ((distance - settings.holdDistance) / distance)
            current.position += (target - current.position) * follow
        }

        if Self.angle(current.normal, normal) > settings.holdAngle {
            current.normal = simd_normalize(current.normal + (normal - current.normal) * follow)
        }

        // Keep the facing on the (possibly new) surface, then turn only when far enough round.
        current.facing = Self.facing(towards: current.facing, normal: current.normal)
        let facingError = Self.angle(current.facing, wantedFacing)
        if facingError > settings.facingHoldAngle { turning = true }
        if turning {
            let ease = 1 - exp(-dt / settings.facingTime)
            current.facing = Self.facing(towards: current.facing + (wantedFacing - current.facing) * ease, normal: current.normal)
            if Self.angle(current.facing, wantedFacing) < 2 * .pi / 180 { turning = false }
        }

        aim = current
        return current
    }

    /// Floors (and ceilings) near level are exactly level; walls exactly upright.
    private func level(_ n: Vec3, kind: SurfaceKind) -> Vec3 {
        switch kind {
        case .floor:
            let up = Vec3(0, n.y >= 0 ? 1 : -1, 0)
            return Self.angle(n, up) < settings.levelAngle ? up : n
        case .wall:
            let flat = Vec3(n.x, 0, n.z)
            return simd_length(flat) > 1e-4 && abs(n.y) < sin(settings.levelAngle) ? simd_normalize(flat) : n
        }
    }

    /// `direction` laid flat along the surface.
    private static func facing(towards direction: Vec3, normal: Vec3) -> Vec3 {
        let along = direction - normal * simd_dot(direction, normal)
        if simd_length(along) > 1e-4 { return simd_normalize(along) }
        let fallback: Vec3 = abs(normal.y) < 0.9 ? [0, 1, 0] : [0, 0, 1]
        return simd_normalize(fallback - normal * simd_dot(fallback, normal))
    }

    private static func angle(_ a: Vec3, _ b: Vec3) -> Float {
        acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b)))))
    }
}
