//
//  PoseTransfer.swift
//  Keeps the paint when the chameleon changes pose.
//
//  Every pose is built from the same thirty parts in the same order — body, head, snout,
//  casque, two eyes, four two-part legs, a sixteen-segment tail (CharacterSDF) — only
//  placed differently. So a point on the new pose can be traced back to the same place on
//  the old one: find the part it belongs to, say where it sits on that part (how far along
//  it, which way round it, how far out), put it at the same place on that part in the old
//  pose, and take the colour of the paint there. The head's paint stays on the head, a
//  stripe down the tail stays down the tail, wherever the tail has gone.
//
//  Where parts melt into each other the answer is a little blurry, which a touch of paint
//  fixes; the alternative was wiping the whole job.
//

import simd

struct PoseTransfer: Sendable {

    private let fromParts: [CharacterSDF.Part]
    private let toParts: [CharacterSDF.Part]
    private let fromEyes: [CharacterSDF.Eye]
    private let toEyes: [CharacterSDF.Eye]
    /// The meshes are lifted to rest on the surface; the parts aren't.
    private let fromLift: Vec3
    private let toLift: Vec3
    private let from: CharacterGeometry
    private let to: CharacterGeometry
    private let colours: [Color3]

    /// - Parameters:
    ///   - from: the pose being left, with its paint (RGBA8, `atlasWidth * atlasHeight * 4`).
    ///   - to: the pose being taken up.
    init?(from: CharacterGeometry, pixels: [UInt8], to: CharacterGeometry) {
        let fromField = CharacterSDF.make(from.pose)
        let toField = CharacterSDF.make(to.pose)
        guard fromField.parts.count == toField.parts.count,
              pixels.count == from.atlasWidth * from.atlasHeight * 4 else { return nil }
        fromParts = fromField.parts
        toParts = toField.parts
        fromEyes = fromField.eyes
        toEyes = toField.eyes
        fromLift = Self.lift(geometry: from, field: fromField)
        toLift = Self.lift(geometry: to, field: toField)
        self.from = from
        self.to = to
        var colours = [Color3](repeating: PaintCanvas.baseColor, count: from.atlasWidth * from.atlasHeight)
        for texel in from.validTexels {
            let i = Int(texel) * 4
            colours[Int(texel)] = Color3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
        }
        self.colours = colours
    }

    /// The paint for a point on the new pose (mesh space) facing `normal`.
    func colour(at position: Vec3, normal: Vec3) -> Color3? {
        let p = position - toLift
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, part) in toParts.enumerated() {
            let d = part.distance(p)
            if d < bestDistance { bestDistance = d; best = index }
        }
        let place = Self.local(p, on: toParts[best], frame: frame(of: best, parts: toParts, eyes: toEyes))
        let oldFrame = frame(of: best, parts: fromParts, eyes: fromEyes)
        let oldPoint = Self.world(place, on: fromParts[best], frame: oldFrame) + fromLift
        let newFrame = frame(of: best, parts: toParts, eyes: toEyes)
        let n = Vec3(simd_dot(normal, newFrame.x), simd_dot(normal, newFrame.y), simd_dot(normal, newFrame.axis))
        let oldNormal = simd_normalize(oldFrame.x * n.x + oldFrame.y * n.y + oldFrame.axis * n.z)
        return nearestColour(to: oldPoint, facing: oldNormal)
    }

    /// The new pose's whole atlas, painted (RGBA8), unpainted texels left the base colour.
    func paintedAtlas() -> [UInt8] {
        let count = to.atlasWidth * to.atlasHeight
        var pixels = [UInt8](repeating: 255, count: count * 4)
        let (r, g, b) = packRGBA(PaintCanvas.baseColor)
        for i in 0..<count { pixels[i * 4] = r; pixels[i * 4 + 1] = g; pixels[i * 4 + 2] = b }
        let texels = to.validTexels
        let geometry = to
        pixels.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendablePointer(base: buffer.baseAddress!)
            Parallel.forEachChunk(count: texels.count, minimumChunk: 2048) { range in
                for k in range {
                    let texel = Int(texels[k])
                    guard let c = colour(at: geometry.texelPositions[texel], normal: geometry.texelNormals[texel]) else { continue }
                    let (r, g, b) = packRGBA(c)
                    out.base[texel * 4] = r
                    out.base[texel * 4 + 1] = g
                    out.base[texel * 4 + 2] = b
                }
            }
        }
        return pixels
    }

    // MARK: - Where a point sits on a part

    private struct Frame {
        var x: Vec3
        var y: Vec3
        var axis: Vec3
    }

    /// Position along the part (0 at `a`, 1 at `b`), and the offset from its axis in the
    /// part's own frame, in units of its radius.
    private struct Place {
        var along: Float
        var offset: Vec3
    }

    /// A frame that turns with the part: along its axis, with "up" as close to the pose's
    /// up as the axis allows. Eyes are balls, so they use the way they look.
    private func frame(of index: Int, parts: [CharacterSDF.Part], eyes: [CharacterSDF.Eye]) -> Frame {
        let part = parts[index]
        var axis = part.b - part.a
        if simd_length(axis) < 1e-5 {
            let eye = eyes.min { simd_distance($0.centre, part.a) < simd_distance($1.centre, part.a) }
            axis = eye?.look ?? [0, 0, 1]
        }
        axis = simd_normalize(axis)
        var reference = Vec3(0, 1, 0)
        if abs(simd_dot(reference, axis)) > 0.9 { reference = [0, 0, 1] }
        let x = simd_normalize(simd_cross(reference, axis))
        return Frame(x: x, y: simd_cross(axis, x), axis: axis)
    }

    private static func local(_ p: Vec3, on part: CharacterSDF.Part, frame: Frame) -> Place {
        let centre = (part.a + part.b) * 0.5
        let q = centre + (p - centre) / part.squash
        let ba = part.b - part.a
        let lengthSquared = simd_dot(ba, ba)
        let along = lengthSquared > 1e-10 ? clamp01(simd_dot(q - part.a, ba) / lengthSquared) : 0
        let offset = (q - (part.a + ba * along)) / max(part.radius, 1e-4)
        return Place(along: along, offset: Vec3(simd_dot(offset, frame.x), simd_dot(offset, frame.y), simd_dot(offset, frame.axis)))
    }

    private static func world(_ place: Place, on part: CharacterSDF.Part, frame: Frame) -> Vec3 {
        let axisPoint = part.a + (part.b - part.a) * place.along
        let offset = (frame.x * place.offset.x + frame.y * place.offset.y + frame.axis * place.offset.z) * part.radius
        let centre = (part.a + part.b) * 0.5
        return centre + (axisPoint + offset - centre) * part.squash
    }

    // MARK: - Reading the old paint

    /// The painted colour closest to `point` on the old pose, preferring the side facing
    /// the same way so thin parts don't borrow paint from their far side.
    private func nearestColour(to point: Vec3, facing normal: Vec3) -> Color3? {
        for (radius, needsFacing) in [(Float(0.012), true), (0.03, false)] {
            var best = -1
            var bestDistance = Float.greatestFiniteMagnitude
            from.grid.forEachTexel(near: point, radius: radius) { texel in
                if needsFacing, simd_dot(from.texelNormals[texel], normal) < 0.2 { return }
                let d = simd_distance_squared(from.texelPositions[texel], point)
                if d < bestDistance { bestDistance = d; best = texel }
            }
            if best >= 0 { return colours[best] }
        }
        return nil
    }

    private static func lift(geometry: CharacterGeometry, field: CharacterSDF) -> Vec3 {
        guard let lifted = geometry.eyes.first, let original = field.eyes.first else { return .zero }
        return lifted.centre - original.centre
    }
}
