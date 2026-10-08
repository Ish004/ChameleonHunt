//
//  LightingMatch.swift
//  Keeps the painted character as bright as the room it's hiding in.
//
//  The paint is made from the scan, which bakes in whatever exposure and white
//  balance the camera had while scanning — often darker, because the hider is close
//  and shading the surface. During the hunt the camera exposes for a different view,
//  so the same colors no longer match and the character stands out as a dark patch.
//
//  This compares like with like: for points on screen around the character it takes
//  the live camera color and the color the *scan* recorded for the very same surface
//  (by ray casting the scanned crop), and takes the median ratio. That ratio, applied
//  to the paint, cancels out both the brightness and the color-temperature difference.
//
//  The same comparison, made right *behind* the chameleon, answers a second question:
//  does that surface still look the way the scan says, once exposure is accounted for?
//  A matte wall does. A TV, a mirror, a window or a glossy table doesn't — the
//  reflection moves as you move, or the picture changes — and there a paint job taken
//  from the scan can't keep matching. How far it disagrees is `viewDependence`, and it
//  lets the chameleon borrow some of the live camera image (see ChameleonActor).
//

import ARKit
import RealityKit
import UIKit

@MainActor
final class LightingMatch {

    /// Multiplier applied to the paint, in linear light.
    private(set) var gain: Color3 = [1, 1, 1]
    private(set) var sampleCount = 0
    /// How much the surface behind the chameleon disagrees with the scan after the
    /// exposure match, 0 (matte, as scanned) … 1 (a mirror or a TV that's on).
    private(set) var viewDependence: Float = 0
    private var smoothed: Color3 = [1, 1, 1]
    private var lastApplied: Color3 = [1, 1, 1]
    private var lastUpdate: TimeInterval = 0

    func reset() {
        viewDependence = 0
        gain = [1, 1, 1]
        smoothed = [1, 1, 1]
        lastApplied = [1, 1, 1]
        sampleCount = 0
    }

    /// Returns a new gain when it has changed enough to be worth re-tinting the paint.
    func update(frame: ARFrame, arView: ARView, scene: HideScene,
                presenter: CharacterPresenter, orientation: UIInterfaceOrientation) -> Color3? {
        guard frame.timestamp - lastUpdate > 0.3, case .normal = frame.camera.trackingState,
              let center = presenter.worldCenter, let projected = arView.project(center) else { return nil }
        lastUpdate = frame.timestamp

        let viewSize = arView.bounds.size
        let bounds = arView.bounds.insetBy(dx: 12, dy: 12)
        let worldToAnchor = scene.anchorToWorld.inverse
        let environment = scene.environment

        var ratios: [Color3] = []
        ratios.reserveCapacity(24)
        for radius in [CGFloat(90), 150, 220] {
            for step in 0..<8 {
                let angle = CGFloat(step) * .pi / 4 + (radius == 150 ? .pi / 8 : 0)
                let point = CGPoint(x: projected.x + cos(angle) * radius, y: projected.y + sin(angle) * radius)
                guard bounds.contains(point), let ray = arView.ray(through: point) else { continue }
                // Skip anything looking at the character itself.
                if presenter.rayHitsCharacter(origin: ray.origin, direction: ray.direction) { continue }

                let origin = worldToAnchor.transformPoint(ray.origin)
                let direction = simd_normalize(worldToAnchor.transformDirection(ray.direction))
                guard let hit = environment.trace(origin: origin, direction: direction, tMin: 0, tMax: 4),
                      let live = CameraColorSampler.color(from: frame, at: point, viewportSize: viewSize,
                                                          orientation: orientation) else { continue }

                let scanned = linear(hit.color)
                let measured = linear(live)
                // Mid-tones only: near-black and blown-out pixels say nothing about exposure.
                guard scanned.min() > 0.02, scanned.max() < 0.92, measured.max() < 0.97 else { continue }
                ratios.append(measured / simd_max(scanned, Color3(repeating: 0.02)))
            }
        }

        sampleCount = ratios.count
        if let updated = LightingEstimate.gain(from: ratios, previous: smoothed) {
            smoothed = updated
            gain = smoothed
        }
        measureViewDependence(frame: frame, arView: arView, scene: scene, presenter: presenter,
                              orientation: orientation)
        guard !ratios.isEmpty else { return nil }
        guard simd_reduce_max(abs(smoothed - lastApplied)) > 0.025 else { return nil }
        lastApplied = smoothed
        return smoothed
    }

    /// Live colour against scanned colour × gain, at points right behind the chameleon.
    private func measureViewDependence(frame: ARFrame, arView: ARView, scene: HideScene,
                                       presenter: CharacterPresenter, orientation: UIInterfaceOrientation) {
        guard let actor = presenter.actor else { return }
        let viewSize = arView.bounds.size
        let bounds = arView.bounds.insetBy(dx: 8, dy: 8)
        let worldToAnchor = scene.anchorToWorld.inverse
        let toWorld = actor.characterToWorld
        let chunks = actor.chunks.chunks
        let step = max(1, chunks.count / 28)
        var residuals: [Float] = []
        for index in stride(from: 0, to: chunks.count, by: step) {
            guard let point = arView.project(toWorld.transformPoint(chunks[index].centre)), bounds.contains(point),
                  let ray = arView.ray(through: point) else { continue }
            let origin = worldToAnchor.transformPoint(ray.origin)
            let direction = simd_normalize(worldToAnchor.transformDirection(ray.direction))
            guard let hit = scene.environment.trace(origin: origin, direction: direction, tMin: 0, tMax: 5),
                  let live = CameraColorSampler.color(from: frame, at: point, viewportSize: viewSize,
                                                      orientation: orientation) else { continue }
            let expected = linear(hit.color) * gain
            let measured = linear(live)
            // Relative difference, so dark and bright surfaces count the same.
            let difference = simd_length(measured - expected) / (simd_length(expected) + 0.06)
            residuals.append(difference)
        }
        guard residuals.count >= 4 else { return }
        let median = LightingEstimate.median(residuals)
        // A matte surface lands under ~0.15 (camera noise, small misregistration); a
        // reflection or a screen is well above 0.5.
        let target = min(max((median - 0.15) / 0.4, 0), 1)
        viewDependence += (target - viewDependence) * 0.35
    }

    private func linear(_ color: Color3) -> Color3 {
        Color3(srgbToLinear(color.x), srgbToLinear(color.y), srgbToLinear(color.z))
    }

}
