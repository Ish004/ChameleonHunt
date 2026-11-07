//
//  MascotRenderer.swift
//  Draws the chameleon as a finished little toy — green, shaded, with proper eyes — for
//  the menus, the pose picker and the hint.
//
//  It renders the game's own geometry rather than using a drawing, for the same reason
//  the old flat silhouette did: the thing on the start screen is exactly the thing you
//  are about to hide, and it can never drift out of step with the model. What changed is
//  that a flat stencil read as a warning sign; a lit, coloured figure reads as a
//  character someone would want to play with.
//
//  A small CPU rasterizer: triangles into a z-buffer at twice the output size, per-pixel
//  normals, a toy-vinyl lighting model (wrapped key light, cool fill, soft sheen, rim),
//  colour by region (eyes, belly, back), a soft contact shadow, then downsampled. Plain
//  Swift so the offline preview tool can produce exactly the same picture.
//

import Foundation
import simd

enum MascotRenderer {

    enum View: Sendable, Hashable {
        /// Three-quarter from the front, a little above: the default portrait.
        case hero
        case side
        case front

        var direction: Vec3 {
            switch self {
            case .hero:  return simd_normalize([0.78, 0.46, 0.92])
            case .side:  return simd_normalize([1, 0.18, 0.06])
            case .front: return simd_normalize([0.12, 0.30, 1])
            }
        }
    }

    /// Where the chameleon sits in the picture.
    private struct Framing: Sendable {
        var centre: Vec3
        var pixelsPerMetre: Float
        var offsetX: Float
        var offsetY: Float
    }

    /// Colours as a designer would pick them (sRGB); converted to linear for lighting.
    /// Giving the lighting sRGB values directly is what made the first render a pale
    /// mint — every colour came out a stop too light and half as saturated.
    struct Palette: Sendable {
        var body: Vec3 = [0.36, 0.71, 0.28]        // leaf green
        var back: Vec3 = [0.20, 0.52, 0.24]
        var belly: Vec3 = [0.86, 0.90, 0.47]       // pale lime
        var sclera: Vec3 = [0.98, 0.97, 0.93]
        var pupil: Vec3 = [0.11, 0.12, 0.13]
        /// A skin's second colour, laid over the body in `pattern` (ChameleonSkin).
        var accent: Vec3 = [0.36, 0.71, 0.28]
        var pattern: Pattern = .plain
        /// Whether these are the colours converted for lighting (`linear`) rather than as picked.
        private(set) var isLinear = false

        var linear: Palette {
            func l(_ c: Vec3) -> Vec3 { Vec3(MascotRenderer.decode(c.x), MascotRenderer.decode(c.y), MascotRenderer.decode(c.z)) }
            return Palette(body: l(body), back: l(back), belly: l(belly), sclera: l(sclera), pupil: l(pupil),
                           accent: l(accent), pattern: pattern, isLinear: true)
        }

        /// The body's colour, and its darker back, at a point of the chameleon (`lo`…`hi`
        /// are its bounds): the plain colours, or the pattern's.
        func surface(at p: Vec3, lo: Vec3, hi: Vec3) -> (body: Vec3, back: Vec3) {
            let share = pattern.share(at: p, lo: lo, hi: hi)
            switch pattern {
            case .plain:
                return (body, back)
            case .rainbow:
                // Along its length, red through to violet.
                let hues: [Vec3] = [[1.0, 0.25, 0.25], [1.0, 0.60, 0.10], [1.0, 0.90, 0.15], [0.25, 0.80, 0.30],
                                    [0.20, 0.55, 1.0], [0.55, 0.30, 0.95]]
                let position = share * Float(hues.count - 1)
                let index = min(Int(position), hues.count - 2)
                let c = hues[index] + (hues[index + 1] - hues[index]) * (position - Float(index))
                let colour = isLinear ? Vec3(MascotRenderer.decode(c.x), MascotRenderer.decode(c.y), MascotRenderer.decode(c.z)) : c
                return (colour, colour * 0.8)
            default:
                let colour = body + (accent - body) * share
                return (colour, back + (accent * 0.8 - back) * share)
            }
        }
    }

    /// How a skin's second colour is laid over the body.
    enum Pattern: Sendable, Equatable {
        case plain
        /// Bands across the body, nose to tail.
        case stripes
        case spots
        /// A soft glint along the top: gold.
        case sheen
        /// Not a second colour but every colour, nose to tail.
        case rainbow

        /// How much of the accent shows at a point, 0…1 (for rainbow: how far along).
        func share(at p: Vec3, lo: Vec3, hi: Vec3) -> Float {
            // Along the chameleon's length: whichever way it's longer on the ground.
            let size = hi - lo
            let lengthwise = size.x >= size.z
            let along = lengthwise ? (p.x - lo.x) / max(size.x, 1e-4) : (p.z - lo.z) / max(size.z, 1e-4)
            switch self {
            case .plain:
                return 0
            case .stripes:
                // Seven bands, with soft edges, a little wavy so they look grown, not printed.
                let across = lengthwise ? p.z : p.x
                let wave = sin(across * 60) * 0.012 + sin(p.y * 45) * 0.01
                let band = abs(sin((along + wave) * .pi * 7))
                return smoothstep(0.62, 0.78, band)
            case .spots:
                // Round spots: little balls on a grid through the chameleon, sized to it,
                // showing wherever its skin cuts through one.
                let cell = max(size.x, size.z) / 4.6
                let q = p / cell + Vec3(0.25, 0.4, 0.1)
                let nearest = Vec3(q.x.rounded(), q.y.rounded(), q.z.rounded())
                let distance = simd_length(q - nearest)
                return 1 - smoothstep(0.30, 0.36, distance)
            case .sheen:
                // Light catching the top, and a band of it along the flank.
                let up = (p.y - lo.y) / max(size.y, 1e-4)
                let band = 1 - smoothstep(0.0, 0.10, abs(up - 0.42 - along * 0.12))
                return max(smoothstep(0.62, 1.0, up) * 0.85, band * 0.6)
            case .rainbow:
                return min(max(along, 0), 1)
            }
        }
    }

    struct Image: Sendable {
        var width: Int
        var height: Int
        /// RGBA8, premultiplied alpha, row 0 at the top.
        var pixels: [UInt8]
    }

    /// - Parameters:
    ///   - size: output width and height in pixels.
    static func render(_ pose: CharacterPose, view: View = .hero, size: Int = 512,
                       palette: Palette = Palette(), shadow: Bool = true) -> Image {
        let (mesh, eyes) = shape(pose)
        return render(mesh: mesh, eyes: eyes, view: view, size: size, palette: palette, shadow: shadow)
    }

    private static func shape(_ pose: CharacterPose) -> (QuadMesh, [CharacterSDF.Eye]) {
        let field = CharacterSDF.make(pose)
        var mesh = SurfaceNets.polygonize(field, cellSize: 0.0045)
        // Same lift the game applies, so the eyes line up with the mesh.
        let lowest = mesh.positions.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
        let lift = Vec3(0, lowest.isFinite ? 0.002 - lowest : 0, 0)
        for i in mesh.positions.indices { mesh.positions[i] += lift }
        let eyes = field.eyes.map { CharacterSDF.Eye(centre: $0.centre + lift, radius: $0.radius, look: $0.look) }
        return (mesh, eyes)
    }

    /// Fits the chameleon as seen from `directions`, leaving room below for the shadow.
    private static func framing(_ mesh: QuadMesh, directions: [Vec3], big: Int) -> Framing {
        var lo = Vec3(repeating: .greatestFiniteMagnitude)
        var hi = Vec3(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let centre = (lo + hi) * 0.5
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for toEye in directions {
            let right = simd_normalize(simd_cross([0, 1, 0], toEye))
            let up = simd_cross(toEye, right)
            for p in mesh.positions {
                let o = p - centre
                let x = simd_dot(o, right), y = simd_dot(o, up)
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let spanX = maxX - minX, spanY = (maxY - minY) * 1.12
        let pixelsPerMetre = Float(big) * 0.80 / max(spanX, spanY)
        return Framing(centre: centre, pixelsPerMetre: pixelsPerMetre,
                       offsetX: Float(big) * 0.5 - (minX + maxX) * 0.5 * pixelsPerMetre,
                       offsetY: Float(big) * 0.5 + ((minY + maxY) * 0.5 + (maxY - minY) * 0.05) * pixelsPerMetre)
    }

    static func render(mesh: QuadMesh, eyes: [CharacterSDF.Eye], view: View, size: Int,
                       palette display: Palette, shadow: Bool) -> Image {
        let palette = display.linear
        let scale = 2
        let big = size * scale
        let toEye = view.direction
        let right = simd_normalize(simd_cross([0, 1, 0], toEye))
        let up = simd_cross(toEye, right)

        var lo = Vec3(repeating: .greatestFiniteMagnitude)
        var hi = Vec3(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let framing = framing(mesh, directions: [toEye], big: big)
        let centre = framing.centre
        let pixelsPerMetre = framing.pixelsPerMetre
        let offsetX = framing.offsetX
        let offsetY = framing.offsetY

        @inline(__always) func project(_ p: Vec3) -> Vec3 {
            let o = p - centre
            return Vec3(simd_dot(o, right) * pixelsPerMetre + offsetX,
                        offsetY - simd_dot(o, up) * pixelsPerMetre,
                        -simd_dot(o, toEye))           // smaller = nearer
        }

        let count = big * big
        var depth = [Float](repeating: .greatestFiniteMagnitude, count: count)
        var normalBuffer = [Vec3](repeating: .zero, count: count)
        var positionBuffer = [Vec3](repeating: .zero, count: count)

        let projected = mesh.positions.map(project)
        for quad in mesh.quads {
            let ids = [Int(quad[0]), Int(quad[1]), Int(quad[2]), Int(quad[3])]
            for tri in [[ids[0], ids[1], ids[2]], [ids[0], ids[2], ids[3]]] {
                let a = projected[tri[0]], b = projected[tri[1]], c = projected[tri[2]]
                let x0 = max(Int(floor(min(a.x, b.x, c.x))), 0), x1 = min(Int(ceil(max(a.x, b.x, c.x))), big - 1)
                let y0 = max(Int(floor(min(a.y, b.y, c.y))), 0), y1 = min(Int(ceil(max(a.y, b.y, c.y))), big - 1)
                guard x0 <= x1, y0 <= y1 else { continue }
                let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
                guard abs(area) > 1e-9 else { continue }
                let na = mesh.normals[tri[0]], nb = mesh.normals[tri[1]], nc = mesh.normals[tri[2]]
                let pa = mesh.positions[tri[0]], pb = mesh.positions[tri[1]], pc = mesh.positions[tri[2]]
                for y in y0...y1 {
                    let py = Float(y) + 0.5
                    for x in x0...x1 {
                        let px = Float(x) + 0.5
                        let w1 = ((px - a.x) * (c.y - a.y) - (c.x - a.x) * (py - a.y)) / area
                        let w2 = ((b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y)) / area
                        let w0 = 1 - w1 - w2
                        guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                        let z = a.z * w0 + b.z * w1 + c.z * w2
                        let i = y * big + x
                        guard z < depth[i] else { continue }
                        depth[i] = z
                        normalBuffer[i] = na * w0 + nb * w1 + nc * w2
                        positionBuffer[i] = pa * w0 + pb * w1 + pc * w2
                    }
                }
            }
        }

        // Shade.
        let key = simd_normalize(Vec3(-0.45, 0.85, 0.55))
        let fill = simd_normalize(Vec3(0.8, 0.15, 0.35))
        var colour = [Vec3](repeating: .zero, count: count)
        var alpha = [Float](repeating: 0, count: count)
        let height = max(hi.y - lo.y, 1e-4)
        for i in 0..<count where depth[i] < .greatestFiniteMagnitude {
            let rawNormal = normalBuffer[i]
            let n = simd_length(rawNormal) > 1e-6 ? simd_normalize(rawNormal) : Vec3(0, 1, 0)
            let p = positionBuffer[i]

            let surface = palette.surface(at: p, lo: lo, hi: hi)
            var albedo = surface.body
            var shininess: Float = 28, sheen: Float = 0.22
            // Darker along the back, pale on the belly: the countershading real lizards
            // have, which also gives the shape a readable top and bottom.
            let topness = smoothstep(0.35, 0.95, n.y)
            albedo = albedo + (surface.back - albedo) * topness * 0.55
            let underneath = smoothstep(-0.05, -0.6, n.y) * (1 - smoothstep(0.35, 0.75, (p.y - lo.y) / height))
            albedo = albedo + (palette.belly - albedo) * underneath

            for eye in eyes {
                let offset = p - eye.centre
                let distance = simd_length(offset)
                guard distance < eye.radius * 1.08 else { continue }
                let facing = simd_dot(offset / max(distance, 1e-5), eye.look)
                if facing > 0.80 {
                    albedo = palette.pupil; shininess = 90; sheen = 0.9
                } else {
                    let blend = smoothstep(0.62, 0.80, facing)
                    albedo = palette.sclera + (palette.pupil - palette.sclera) * blend
                    shininess = 60; sheen = 0.45
                }
            }

            let wrapped = max(0, (simd_dot(n, key) + 0.30) / 1.30)
            let fillLight = max(0, simd_dot(n, fill)) * 0.22
            let sky = 0.16 + 0.14 * (n.y * 0.5 + 0.5)
            let halfway = simd_normalize(key + toEye)
            let specular = pow(max(0, simd_dot(n, halfway)), shininess) * sheen
            let rim = pow(1 - max(0, simd_dot(n, toEye)), 3) * 0.10

            var lit = albedo * (wrapped * 0.95 + fillLight * Vec3(0.85, 0.95, 1.05) + sky)
            lit += Vec3(repeating: specular * 0.7 + rim * 0.5)
            colour[i] = simd_min(lit, Vec3(repeating: 1))
            alpha[i] = 1
        }

        // Soft contact shadow under the lowest part of the body.
        var shadowAlpha = [Float](repeating: 0, count: count)
        if shadow {
            var footprint: [Vec3] = []
            for p in mesh.positions where p.y < lo.y + 0.02 { footprint.append(project(Vec3(p.x, lo.y, p.z))) }
            if !footprint.isEmpty {
                let cx = footprint.reduce(0) { $0 + $1.x } / Float(footprint.count)
                let cy = footprint.reduce(0) { $0 + $1.y } / Float(footprint.count)
                var rx: Float = 1, ry: Float = 1
                for f in footprint { rx = max(rx, abs(f.x - cx)); ry = max(ry, abs(f.y - cy)) }
                rx *= 1.15; ry = max(ry * 1.3, rx * 0.2)
                // Falls to exactly zero at the ellipse's edge: a Gaussian's long tail got
                // clipped by the image border and showed as a faint box round the figure.
                let edgeMargin = Float(big) * 0.02
                for y in 0..<big {
                    for x in 0..<big {
                        let dx = (Float(x) - cx) / rx, dy = (Float(y) - cy) / ry
                        let d = (dx * dx + dy * dy).squareRoot()
                        guard d < 1 else { continue }
                        let border = min(Float(x), Float(y), Float(big - 1 - x), Float(big - 1 - y))
                        let fade = min(1, max(0, border / edgeMargin))
                        let falloff = (1 - d) * (1 - d)
                        shadowAlpha[y * big + x] = 0.26 * falloff * fade
                    }
                }
            }
        }

        // Downsample.
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let samples = Float(scale * scale)
        for y in 0..<size {
            for x in 0..<size {
                var rgb = Vec3.zero
                var covered: Float = 0
                var shade: Float = 0
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        let i = (y * scale + sy) * big + (x * scale + sx)
                        if alpha[i] > 0 { rgb += colour[i]; covered += 1 } else { shade += shadowAlpha[i] }
                    }
                }
                // Encode the straight colour, then premultiply by how much of the pixel
                // the figure covers; the shadow is black, so it only adds alpha.
                let coverage = covered / samples
                let straight = covered > 0 ? rgb / covered : .zero
                let a = min(1, coverage + shade / samples)
                let o = (y * size + x) * 4
                pixels[o] = UInt8(min(255, max(0, sRGBEncode(straight.x) * coverage * 255)))
                pixels[o + 1] = UInt8(min(255, max(0, sRGBEncode(straight.y) * coverage * 255)))
                pixels[o + 2] = UInt8(min(255, max(0, sRGBEncode(straight.z) * coverage * 255)))
                pixels[o + 3] = UInt8(min(255, max(0, a * 255)))
            }
        }
        return Image(width: size, height: size, pixels: pixels)
    }

    /// Light is worked out in a roughly linear space and the result is lifted for
    /// display — without it the shading looks muddy and flat.
    @inline(__always) static func decode(_ v: Float) -> Float {
        let c = max(0, min(1, v))
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always) private static func sRGBEncode(_ v: Float) -> Float {
        let c = max(0, min(1, v))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
