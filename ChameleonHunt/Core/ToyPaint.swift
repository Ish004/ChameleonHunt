//
//  ToyPaint.swift
//  The chameleon in its own colours, as a paint job: the mascot's countershaded green,
//  pale belly and big eyes, with soft light from above baked in.
//
//  Used where the chameleon should look like itself in the room rather than hide: the
//  preview while dropping chameleons in the lots-of-them game, and the first moment after
//  each one lands, before the room's colours wash over it. The light is baked because
//  the chameleons are drawn unlit (so camouflage colours stay exactly as matched); without
//  it the toy colours would read as a flat green cut-out.
//

import Foundation
import simd

enum ToyPaint {

    static func pixels(for geometry: CharacterGeometry,
                       palette display: MascotRenderer.Palette = MascotRenderer.Palette()) -> [UInt8] {
        let palette = display.linear
        var pixels = [UInt8](repeating: 255, count: geometry.atlasWidth * geometry.atlasHeight * 4)
        let lo = geometry.boundsMin, hi = geometry.boundsMax
        let height = max(hi.y - lo.y, 1e-4)
        let key = simd_normalize(Vec3(-0.45, 0.85, 0.55))
        let eyes = geometry.eyes

        for texel in geometry.validTexels {
            let t = Int(texel)
            let p = geometry.texelPositions[t]
            let n = geometry.texelNormals[t]

            let surface = palette.surface(at: p, lo: lo, hi: hi)
            var albedo = surface.body
            let topness = smoothstep(0.35, 0.95, n.y)
            albedo += (surface.back - albedo) * topness * 0.55
            let underneath = smoothstep(-0.05, -0.6, n.y) * (1 - smoothstep(0.35, 0.75, (p.y - lo.y) / height))
            albedo += (palette.belly - albedo) * underneath
            var isEye = false
            for eye in eyes {
                let offset = p - eye.centre
                let distance = simd_length(offset)
                guard distance < eye.radius * 1.08 else { continue }
                let facing = simd_dot(offset / max(distance, 1e-5), eye.look)
                albedo = facing > 0.80 ? palette.pupil
                    : palette.sclera + (palette.pupil - palette.sclera) * smoothstep(0.62, 0.80, facing)
                isEye = true
            }

            let wrapped = max(0, (simd_dot(n, key) + 0.30) / 1.30)
            let sky = 0.18 + 0.16 * (n.y * 0.5 + 0.5)
            let lit = simd_min(albedo * (wrapped * (isEye ? 0.8 : 0.95) + sky), Vec3(repeating: 1))
            let i = t * 4
            pixels[i] = encode(lit.x); pixels[i + 1] = encode(lit.y); pixels[i + 2] = encode(lit.z)
        }
        return pixels
    }

    @inline(__always) private static func encode(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, pow(max(v, 0), 1 / 2.2) * 255)))
    }
}
