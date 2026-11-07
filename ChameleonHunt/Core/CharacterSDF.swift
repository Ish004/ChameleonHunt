//
//  CharacterSDF.swift
//  The hider: a chameleon, built from smooth-unioned capsules.
//
//  Designed as a toy, not a specimen. The first chameleon was anatomically honest —
//  narrow body, long thin legs, blade-thin crest and casque — and standing up it looked
//  like a skeleton. Everything a person reads as "cute" pulls the other way: a big head,
//  big eyes, a fat soft body, short thick legs, a chunky tail. That's the vinyl-toy and
//  plush proportion, and it happens to be better for the game too: thick parts survive
//  the 5 mm voxel grid cleanly, and a compact shape is easier to tuck into a hiding place.
//
//  What still makes it read as a chameleon rather than a frog or a dragon, in order:
//  the tail coiled into a spiral, the big turret eyes standing proud of the head, and a
//  soft helmet-bump (the casque) at the back of the skull.
//
//  Pose space: the origin is the contact point on the surface and +Y is the surface
//  normal. The chameleon faces +Z. For a wall, +Z is world-up, so a climbing chameleon
//  is head-up with its belly against the wall.
//

import simd

enum CharacterPose: String, CaseIterable, Identifiable, Sendable, Codable {
    case standing
    case curled
    case lying
    case clinging

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standing: return "Sitting"
        case .curled:   return "Napping"
        case .lying:    return "Sunbathing"
        case .clinging: return "Climbing"
        }
    }

    /// One line on where the pose works best, in the words a player would use.
    var hint: String {
        switch self {
        case .standing: return "Sat up on a shelf or a table"
        case .curled:   return "Curled into a ball — good for corners and gaps"
        case .lying:    return "Flat out — vanishes on big surfaces"
        case .clinging: return "Stuck to a wall"
        }
    }

    var systemImage: String {
        switch self {
        case .standing: return "lizard.fill"
        case .curled:   return "moon.zzz.fill"
        case .lying:    return "sun.max.fill"
        case .clinging: return "arrow.up.to.line"
        }
    }

    var surface: SurfaceKind { self == .clinging ? .wall : .floor }

    static func poses(for surface: SurfaceKind) -> [CharacterPose] {
        allCases.filter { $0.surface == surface }
    }

    /// Nose-to-tail length of the sitting pose at scale 1, for the size readout.
    static let nominalHeightMeters: Float = 0.34
    /// 8 cm (a real challenge) up to about 50 cm.
    static let scaleRange: ClosedRange<Float> = 0.27...1.65
}

struct CharacterSDF: SignedDistanceField {

    struct Part: Sendable {
        var a: Vec3
        var b: Vec3
        var radius: Float
        /// Smooth-union radius used when merging this part into the body so far.
        var blend: Float
        /// Per-axis squash, for flattened or elongated parts.
        var squash: Vec3 = [1, 1, 1]

        @inline(__always) func distance(_ p: Vec3) -> Float {
            var q = p
            var lipschitz: Float = 1
            if squash != [1, 1, 1] {
                let center = (a + b) * 0.5
                q = center + (p - center) / squash
                lipschitz = min(squash.x, min(squash.y, squash.z))
            }
            let pa = q - a
            let ba = b - a
            let denominator = simd_dot(ba, ba)
            let h = denominator > 0 ? clamp01(simd_dot(pa, ba) / denominator) : 0
            return (simd_length(pa - ba * h) - radius) * lipschitz
        }
    }

    struct Dimple: Sendable {
        var center: Vec3
        var radius: Float
    }

    /// Where the eyes are, so the mascot renderer can colour them. The surface itself
    /// doesn't care; the paint job will cover them anyway once it's hiding.
    struct Eye: Sendable {
        var centre: Vec3
        var radius: Float
        /// Unit direction the pupil faces.
        var look: Vec3
    }

    let parts: [Part]
    let dimples: [Dimple]
    let eyes: [Eye]
    let boundsMin: Vec3
    let boundsMax: Vec3

    init(parts: [Part], dimples: [Dimple] = [], eyes: [Eye] = []) {
        self.parts = parts
        self.dimples = dimples
        self.eyes = eyes
        var lo = Vec3(repeating: .greatestFiniteMagnitude)
        var hi = Vec3(repeating: -.greatestFiniteMagnitude)
        for part in parts {
            let reach = Vec3(repeating: part.radius) * simd_max(part.squash, Vec3(repeating: 1))
                + Vec3(repeating: part.blend * 0.25)
            lo = simd_min(lo, simd_min(part.a, part.b) - reach)
            hi = simd_max(hi, simd_max(part.a, part.b) + reach)
        }
        boundsMin = lo
        boundsMax = hi
    }

    func distance(_ p: Vec3) -> Float {
        var d = parts[0].distance(p)
        for index in 1..<parts.count {
            let part = parts[index]
            d = smoothMin(d, part.distance(p), part.blend)
        }
        for dimple in dimples {
            let e = simd_length(p - dimple.center) - dimple.radius
            d = -smoothMin(-d, e, 0.004)
        }
        return d
    }

    @inline(__always) private func smoothMin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        guard k > 0 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    // MARK: - Building blocks

    typealias P = Part

    /// The tail, wound into a spiral. Thick at the root and tapering, like a toy's —
    /// a thin tail is the first thing that makes it look skeletal.
    /// - Parameters:
    ///   - centre: middle of the coil, behind the hips.
    ///   - u: from the centre towards the body, where the tail leaves it.
    ///   - v: the direction the coil sweeps first.
    private static func coiledTail(centre: Vec3, u: Vec3, v: Vec3, startRadius: Float,
                                   turns: Float, tightening: Float,
                                   thickness: ClosedRange<Float>, segments: Int = 16,
                                   squash: Vec3 = [1, 1, 1]) -> [Part] {
        func point(_ t: Float) -> Vec3 {
            let angle = t * turns * 2 * .pi
            let radius = startRadius * (1 - tightening * t)
            return centre + (u * cos(angle) + v * sin(angle)) * radius
        }
        var parts: [Part] = []
        var previous = point(0)
        for i in 1...segments {
            let t = Float(i) / Float(segments)
            let next = point(t)
            // Ease the taper so the coil stays chunky most of the way round.
            let taper = pow(t, 1.4)
            let width = thickness.upperBound + (thickness.lowerBound - thickness.upperBound) * taper
            parts.append(P(a: previous, b: next, radius: width,
                           blend: i == 1 ? width * 1.2 : width * 0.45, squash: squash))
            previous = next
        }
        return parts
    }

    /// A stubby leg ending in a rounded mitten of a foot.
    private static func stubbyLeg(hip: Vec3, foot: Vec3, thickness: Float,
                                  toeDirection: Vec3 = [0, 0, 1]) -> [Part] {
        let toe = foot + simd_normalize(toeDirection) * thickness * 0.9
        return [
            P(a: hip, b: foot, radius: thickness, blend: thickness * 0.9),
            P(a: foot, b: toe, radius: thickness * 0.92, blend: thickness * 0.6, squash: [1.08, 0.62, 1])
        ]
    }

    private static func mirrored(_ parts: [Part]) -> [Part] {
        parts.map {
            var part = $0
            part.a.x = -part.a.x
            part.b.x = -part.b.x
            return part
        }
    }

    /// A big turret eye: a ball that sits proud of the head, and the shallow pupil
    /// socket that gives the surface a hint of where it's looking.
    private static func turretEye(_ centre: Vec3, radius: Float, look: Vec3) -> (Part, Dimple, Eye) {
        let direction = simd_normalize(look)
        return (P(a: centre, b: centre, radius: radius, blend: radius * 0.35),
                Dimple(center: centre + direction * radius * 1.12, radius: radius * 0.34),
                Eye(centre: centre, radius: radius, look: direction))
    }

    // MARK: - Poses

    static func make(_ pose: CharacterPose) -> CharacterSDF {
        switch pose {

        case .standing:
            // Sat up on four stubby legs, head up, tail coiled behind — the mascot.
            var parts: [Part] = [
                // A soft bean of a body, sitting low.
                P(a: [0, 0.078, -0.030], b: [0, 0.088, 0.026], radius: 0.060, blend: 0, squash: [0.86, 1, 1]),
                // A big head, carried up and forward.
                P(a: [0, 0.140, 0.064], b: [0, 0.146, 0.090], radius: 0.052, blend: 0.034, squash: [0.92, 1, 1]),
                // Short rounded snout.
                P(a: [0, 0.134, 0.112], b: [0, 0.128, 0.134], radius: 0.030, blend: 0.022, squash: [0.94, 0.9, 1]),
                // The casque: a soft rounded helmet at the back of the skull — a bump,
                // not a horn.
                P(a: [0, 0.178, 0.066], b: [0, 0.192, 0.042], radius: 0.028, blend: 0.028, squash: [0.72, 1, 1])
            ]
            var dimples: [Dimple] = []
            var eyes: [Eye] = []
            for side: Float in [1, -1] {
                let (part, dimple, eye) = turretEye([0.043 * side, 0.158, 0.094], radius: 0.029,
                                                    look: [0.55 * side, 0.08, 0.83])
                parts.append(part); dimples.append(dimple); eyes.append(eye)
            }
            let front = stubbyLeg(hip: [0.036, 0.056, 0.042], foot: [0.046, 0.018, 0.054], thickness: 0.021)
            let back = stubbyLeg(hip: [0.038, 0.054, -0.034], foot: [0.049, 0.018, -0.040], thickness: 0.023)
            parts += front + mirrored(front) + back + mirrored(back)
            parts += coiledTail(centre: [0, 0.066, -0.120], u: [0, 0, 1], v: [0, 1, 0],
                                startRadius: 0.046, turns: 1.18, tightening: 0.58,
                                thickness: 0.011...0.026, squash: [0.86, 1, 1])
            return CharacterSDF(parts: parts, dimples: dimples, eyes: eyes)

        case .curled:
            // A nap: curled into a ball, chin down, tail wrapped round the side.
            var parts: [Part] = [
                P(a: [0, 0.064, -0.018], b: [0, 0.066, 0.014], radius: 0.060, blend: 0, squash: [0.95, 0.92, 1]),
                P(a: [0, 0.074, 0.058], b: [0, 0.070, 0.080], radius: 0.044, blend: 0.030, squash: [0.92, 0.94, 1]),
                P(a: [0, 0.064, 0.100], b: [0, 0.056, 0.120], radius: 0.024, blend: 0.020, squash: [0.94, 0.86, 1]),
                P(a: [0, 0.108, 0.058], b: [0, 0.128, 0.034], radius: 0.021, blend: 0.022, squash: [0.62, 1, 1])
            ]
            var dimples: [Dimple] = []
            var eyes: [Eye] = []
            for side: Float in [1, -1] {
                let (part, dimple, eye) = turretEye([0.036 * side, 0.090, 0.080], radius: 0.024,
                                                    look: [0.6 * side, 0.1, 0.79])
                parts.append(part); dimples.append(dimple); eyes.append(eye)
            }
            // Just the feet peeking out from under the ball.
            let front = stubbyLeg(hip: [0.040, 0.034, 0.040], foot: [0.050, 0.016, 0.054], thickness: 0.018)
            let back = stubbyLeg(hip: [0.044, 0.034, -0.030], foot: [0.054, 0.016, -0.026], thickness: 0.019)
            parts += front + mirrored(front) + back + mirrored(back)
            // Wrapped round the side of the ball, flat on the ground.
            parts += coiledTail(centre: [0.036, 0.020, -0.070], u: [-0.3, 0, 0.95], v: [0.95, 0, 0.3],
                                startRadius: 0.052, turns: 1.1, tightening: 0.62,
                                thickness: 0.010...0.021, squash: [1, 0.8, 1])
            return CharacterSDF(parts: parts, dimples: dimples, eyes: eyes)

        case .lying:
            // Flat out in the sun, legs splayed, tail coiled flat beside it.
            var parts: [Part] = [
                P(a: [0, 0.040, -0.034], b: [0, 0.042, 0.030], radius: 0.052, blend: 0, squash: [1.02, 0.66, 1]),
                P(a: [0, 0.050, 0.070], b: [0, 0.050, 0.094], radius: 0.044, blend: 0.030, squash: [0.96, 0.78, 1]),
                P(a: [0, 0.044, 0.118], b: [0, 0.038, 0.144], radius: 0.025, blend: 0.020, squash: [0.96, 0.82, 1]),
                P(a: [0, 0.080, 0.070], b: [0, 0.098, 0.044], radius: 0.020, blend: 0.022, squash: [0.62, 1, 1])
            ]
            var dimples: [Dimple] = []
            var eyes: [Eye] = []
            for side: Float in [1, -1] {
                let (part, dimple, eye) = turretEye([0.036 * side, 0.070, 0.098], radius: 0.024,
                                                    look: [0.6 * side, 0.2, 0.77])
                parts.append(part); dimples.append(dimple); eyes.append(eye)
            }
            let front = stubbyLeg(hip: [0.040, 0.034, 0.044], foot: [0.080, 0.016, 0.064], thickness: 0.018,
                                  toeDirection: [0.5, 0, 1])
            let back = stubbyLeg(hip: [0.042, 0.034, -0.026], foot: [0.084, 0.016, -0.040], thickness: 0.020,
                                 toeDirection: [0.6, 0, -0.4])
            parts += front + mirrored(front) + back + mirrored(back)
            parts += coiledTail(centre: [-0.030, 0.020, -0.100], u: [0.45, 0, 0.9], v: [-0.9, 0, 0.45],
                                startRadius: 0.052, turns: 1.1, tightening: 0.60,
                                thickness: 0.010...0.022, squash: [1, 0.72, 1])
            return CharacterSDF(parts: parts, dimples: dimples, eyes: eyes)

        case .clinging:
            // Climbing a wall. +Y is out of the wall and +Z is up it: belly to the wall,
            // legs spread to grip, tail curled round to the side.
            var parts: [Part] = [
                P(a: [0, 0.036, -0.034], b: [0, 0.038, 0.030], radius: 0.050, blend: 0, squash: [1.0, 0.64, 1]),
                P(a: [0, 0.046, 0.068], b: [0, 0.046, 0.092], radius: 0.042, blend: 0.030, squash: [0.96, 0.76, 1]),
                P(a: [0, 0.040, 0.116], b: [0, 0.034, 0.140], radius: 0.024, blend: 0.020, squash: [0.96, 0.80, 1]),
                P(a: [0, 0.076, 0.066], b: [0, 0.094, 0.040], radius: 0.019, blend: 0.022, squash: [0.62, 1, 1])
            ]
            var dimples: [Dimple] = []
            var eyes: [Eye] = []
            for side: Float in [1, -1] {
                let (part, dimple, eye) = turretEye([0.035 * side, 0.066, 0.096], radius: 0.023,
                                                    look: [0.6 * side, 0.3, 0.74])
                parts.append(part); dimples.append(dimple); eyes.append(eye)
            }
            let front = stubbyLeg(hip: [0.040, 0.030, 0.046], foot: [0.084, 0.014, 0.076], thickness: 0.017,
                                  toeDirection: [0.4, 0, 1])
            let back = stubbyLeg(hip: [0.042, 0.030, -0.028], foot: [0.086, 0.014, -0.052], thickness: 0.019,
                                 toeDirection: [0.4, 0, -1])
            parts += front + mirrored(front) + back + mirrored(back)
            parts += coiledTail(centre: [0.034, 0.018, -0.098], u: [-0.45, 0, 0.9], v: [0.9, 0, 0.45],
                                startRadius: 0.050, turns: 1.1, tightening: 0.60,
                                thickness: 0.010...0.021, squash: [1, 0.70, 1])
            return CharacterSDF(parts: parts, dimples: dimples, eyes: eyes)
        }
    }
}
