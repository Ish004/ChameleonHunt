//
//  ScanRing.swift
//  The scanning guide: a ring of tick marks lying on the surface around the hiding spot,
//  each one lighting up as you look at the spot from its side.
//
//  This is Face ID's enrolment ring moved into the room. Face ID works because it never
//  explains anything — there is one instruction, and a circle that fills in as you do the
//  right thing. The old scan screen was the opposite: a wireframe of the LiDAR mesh, a
//  counter of "camera views", a mapping status, and a Finish button the player had to
//  judge for themselves. Here the ring is laid on the floor (or the wall) around the
//  thing itself, so "walk around it" and "fill the circle" are the same instruction, and
//  you can see at a glance which side you've missed.
//

import RealityKit
import UIKit
import simd

@MainActor
final class ScanRing {

    static let tickCount = 40

    let root = Entity()
    private var ticks: [ModelEntity] = []
    private(set) var filled = [Bool](repeating: false, count: ScanRing.tickCount)
    private let emptyMaterial: UnlitMaterial
    private let filledMaterial: UnlitMaterial

    var progress: Float {
        Float(filled.lazy.filter { $0 }.count) / Float(Self.tickCount)
    }

    init(parent: Entity) {
        var empty = UnlitMaterial(color: UIColor(white: 1, alpha: 0.55))
        empty.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        emptyMaterial = empty
        filledMaterial = UnlitMaterial(color: UIColor(red: 0.30, green: 0.80, blue: 0.40, alpha: 1))

        root.name = "scan-ring"
        root.isEnabled = false
        parent.addChild(root)
        let mesh = MeshResource.generateBox(width: 1, height: 1, depth: 1, cornerRadius: 0.35)
        for _ in 0..<Self.tickCount {
            let tick = ModelEntity(mesh: mesh, materials: [emptyMaterial])
            root.addChild(tick)
            ticks.append(tick)
        }
    }

    /// Lays the ring around a spot. `transform` is the hide anchor: origin on the
    /// surface, +Y out of it — so the same ring works on a floor and on a wall.
    func place(at transform: simd_float4x4, radius: Float) {
        root.transform = Transform(matrix: transform)
        // Ticks grow with the ring so they stay legible from a step or two away.
        let length = max(0.018, radius * 0.16)
        let width = length * 0.30
        for (i, tick) in ticks.enumerated() {
            let angle = Self.angle(of: i)
            tick.position = [cos(angle) * (radius + length * 0.5), 0.004, sin(angle) * (radius + length * 0.5)]
            // Long side pointing out from the centre, like the marks round a watch face.
            tick.orientation = simd_quatf(angle: .pi / 2 - angle, axis: [0, 1, 0])
            tick.scale = [width, 0.0025, length]
        }
        root.isEnabled = true
    }

    func hide() {
        root.isEnabled = false
    }

    func reset() {
        filled = [Bool](repeating: false, count: Self.tickCount)
        for tick in ticks { tick.model?.materials = [emptyMaterial] }
    }

    /// Lights the tick facing `angle` (radians, in the ring's own plane) and its close
    /// neighbours, so a steady walk leaves no gaps. Returns true if anything changed.
    @discardableResult
    func fill(towards angle: Float, spread: Int = 1) -> Bool {
        let step = 2 * Float.pi / Float(Self.tickCount)
        var normalized = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if normalized < 0 { normalized += 2 * .pi }
        let centre = Int((normalized / step).rounded()) % Self.tickCount
        var changed = false
        for offset in -spread...spread {
            let index = (centre + offset + Self.tickCount) % Self.tickCount
            guard !filled[index] else { continue }
            filled[index] = true
            ticks[index].model?.materials = [filledMaterial]
            changed = true
        }
        return changed
    }

    static func angle(of tick: Int) -> Float {
        Float(tick) / Float(tickCount) * 2 * .pi
    }
}
