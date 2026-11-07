//
//  LiveCamouflage.swift
//  The chameleon doing the one thing chameleons are famous for: changing colour, on its
//  own, to match whatever is behind it — from wherever you happen to be looking.
//
//  Hand-painted camouflage has a ceiling. The paint is taken from the scan, at the scan's
//  exposure and from the scan's viewpoints, and it's drawn without lighting — so once the
//  seeker's camera exposes the room differently, or looks from a new angle, or the spot
//  is anything shiny, the chameleon turns into a flat patch of slightly-wrong colour. In
//  testing that patch was usually how it got found.
//
//  The camera, meanwhile, is looking straight through it. The chameleon isn't really
//  there, so the pixel of the live camera image under any part of it is exactly what's
//  behind that part, from this viewpoint, at this exposure. Painting each visible texel
//  with that pixel turns the chameleon into a window. Doing it a few times a second, and
//  easing towards the new colour rather than jumping, gives it a chameleon's lag: stand
//  still and it melts into the background; move quickly and it can't keep up, which
//  leaves a faint shimmer for a sharp-eyed seeker. Only the lots-of-them chameleons do
//  this; the one hand-painted chameleon is hidden by its paint job alone.
//
//  Everything here is plain Swift so it runs off the main thread and can be tested.
//

import Foundation
import simd

/// One chameleon's living colours, kept in a reference so a background update can work
/// on it in place instead of copying ten megabytes of texels every time.
final class LiveSkin: @unchecked Sendable {

    struct Settings: Sendable {
        /// How much of the live colour can show, 0…1. The rest is the hider's paint.
        var strength: Float = 0.6
        /// How far each update moves towards what the camera sees now.
        var adaptRate: Float = 0.45
        /// Texels out of sight drift back to the paint job by this much per update.
        var forgetRate: Float = 0.02
        /// A real surface this much nearer than the texel means something is in front
        /// of it, and the camera pixel is that thing — not what's behind the chameleon.
        var occluderMargin: Float = 0.05
        /// How far the colours drawn sit off the match, 0…1 of full brightness: light
        /// colours that much darker, dark ones that much lighter (HuntDifficulty.tell).
        /// Only what's drawn: the paint and what's been learned stay as they are.
        var tell: Float = 0
    }

    let geometry: CharacterGeometry
    /// The hider's paint job (already adjusted for the room's lighting), RGBA8.
    private(set) var base: [UInt8]
    /// What's drawn: base and live colour mixed, RGBA8.
    private(set) var composed: [UInt8]
    private var colour: [Color3]
    private var weight: [Float]
    /// The tell the composed picture was last drawn with (Settings.tell).
    private(set) var tell: Float = 0

    init(geometry: CharacterGeometry, base: [UInt8]) {
        self.geometry = geometry
        self.base = base
        composed = base
        let count = geometry.atlasWidth * geometry.atlasHeight
        colour = [Color3](repeating: .zero, count: count)
        weight = [Float](repeating: 0, count: count)
    }

    func setBase(_ pixels: [UInt8]) {
        guard pixels.count == base.count else { return }
        base = pixels
        compose()
    }

    /// Forgets everything learned from the camera (and any tell: this is the paint).
    func clear() {
        for i in weight.indices { weight[i] = 0 }
        tell = 0
        composed = base
    }

    /// The same colours, drawn with a different tell (the seeker came closer or backed off).
    func setTell(_ value: Float) {
        guard abs(value - tell) > 0.0005 else { return }
        tell = value
        compose()
    }

    /// `value` (0…1 per channel) moved off the match by `tell`: darker, unless it's
    /// nearly black already, in which case lighter. The two meet in the very dark greys
    /// (easing through nothing there, so there's no seam), which leaves the full tell on
    /// anything from a dark carpet to a white desk.
    static func nudged(_ value: Color3, tell: Float) -> Color3 {
        guard tell > 0 else { return value }
        let luma = 0.2126 * value.x + 0.7152 * value.y + 0.0722 * value.z
        let direction = tanh((luma - 0.15) * 12)
        return value - Color3(repeating: tell * direction)
    }

    /// Mean live weight over the texels that have any — for tests and diagnostics.
    var averageWeight: Float {
        var sum: Float = 0, n = 0
        for texel in geometry.validTexels { sum += weight[Int(texel)]; n += 1 }
        return n > 0 ? sum / Float(n) : 0
    }

    /// One update from a camera frame. Returns how many texels it could see.
    @discardableResult
    func update(from frame: Keyframe, characterToWorld: simd_float4x4, settings: Settings) -> Int {
        guard settings.strength > 0 else { return 0 }
        tell = settings.tell
        let worldToCamera = frame.cameraToWorld.inverse
        let characterToCamera = worldToCamera * characterToWorld
        let worldToCharacter = characterToWorld.inverse
        let eyeInCharacter = worldToCharacter.transformPoint(frame.cameraToWorld.translation)
        // Parts of the chameleon hidden behind other parts of itself can't see through.
        let selfVisibility = VisibilityMap.build(geometry: geometry, eye: eyeInCharacter, size: 192)
        let k = frame.intrinsics
        let width = frame.width, height = frame.height
        let depthScaleX = Float(frame.depthWidth) / Float(width)
        let depthScaleY = Float(frame.depthHeight) / Float(height)
        let texels = geometry.validTexels
        let geometry = self.geometry
        let seen = Counter()

        colour.withUnsafeMutableBufferPointer { colourBuffer in
            weight.withUnsafeMutableBufferPointer { weightBuffer in
                frame.rgba.withUnsafeBufferPointer { rgba in
                    let colourOut = UnsafeSendablePointer(base: colourBuffer.baseAddress!)
                    let weightOut = UnsafeSendablePointer(base: weightBuffer.baseAddress!)
                    let image = UnsafeSendableBuffer(base: rgba)
                    Parallel.forEachChunk(count: texels.count, minimumChunk: 4096) { range in
                        var visibleHere = 0
                        for k2 in range {
                            let texel = Int(texels[k2])
                            let position = geometry.texelPositions[texel]
                            let normal = geometry.texelNormals[texel]
                            let toEye = eyeInCharacter - position
                            let distance = simd_length(toEye)
                            let facing = distance > 1e-5 ? simd_dot(normal, toEye / distance) : 0

                            var visible = facing > 0.08 && selfVisibility.isVisible(position, bias: 0.006)
                            var sample = Color3.zero
                            if visible {
                                let c = characterToCamera.transformPoint(position)
                                let z = -c.z
                                if z > 0.05 {
                                    let u = k.x * c.x / z + k.z
                                    let v = k.y * (-c.y) / z + k.w
                                    if u >= 1, v >= 1, u < Float(width - 1), v < Float(height - 1) {
                                        // Is something real in front of this bit of chameleon?
                                        if frame.depthWidth > 0 {
                                            let dx = min(max(Int(u * depthScaleX), 0), frame.depthWidth - 1)
                                            let dy = min(max(Int(v * depthScaleY), 0), frame.depthHeight - 1)
                                            let real = frame.depth[dy * frame.depthWidth + dx]
                                            if real > 0, real < z - settings.occluderMargin { visible = false }
                                        }
                                        if visible {
                                            sample = EnvironmentGeometry.bilinear(image.base, width: width, height: height,
                                                                                  x: u - 0.5, y: v - 0.5)
                                        }
                                    } else {
                                        visible = false
                                    }
                                } else {
                                    visible = false
                                }
                            }

                            if visible {
                                visibleHere += 1
                                let previous = weightOut.base[texel]
                                if previous <= 0.001 {
                                    colourOut.base[texel] = sample
                                } else {
                                    colourOut.base[texel] += (sample - colourOut.base[texel]) * settings.adaptRate
                                }
                                weightOut.base[texel] = previous + (settings.strength - previous) * settings.adaptRate
                            } else if weightOut.base[texel] > 0 {
                                weightOut.base[texel] = max(0, weightOut.base[texel] - settings.forgetRate)
                            }
                        }
                        _ = seen.add(visibleHere)
                    }
                }
            }
        }
        compose()
        return seen.add(0)
    }

    private func compose() {
        let texels = geometry.validTexels
        let base = self.base
        let colour = self.colour
        let weight = self.weight
        let tell = self.tell
        composed.withUnsafeMutableBufferPointer { out in
            let target = UnsafeSendablePointer(base: out.baseAddress!)
            Parallel.forEachChunk(count: texels.count, minimumChunk: 8192) { range in
                for k in range {
                    let texel = Int(texels[k])
                    let w = weight[texel]
                    let i = texel * 4
                    guard w > 0.002 || tell > 0 else {
                        target.base[i] = base[i]; target.base[i + 1] = base[i + 1]; target.base[i + 2] = base[i + 2]
                        continue
                    }
                    let painted = Color3(Float(base[i]), Float(base[i + 1]), Float(base[i + 2])) / 255
                    let matched = w > 0.002 ? painted + (colour[texel] - painted) * w : painted
                    let (r, g, b) = packRGBA(Self.nudged(matched, tell: tell))
                    target.base[i] = r; target.base[i + 1] = g; target.base[i + 2] = b
                }
            }
        }
    }
}

/// A read-only buffer that can be shared with the parallel workers.
struct UnsafeSendableBuffer<T>: @unchecked Sendable {
    let base: UnsafeBufferPointer<T>
}
