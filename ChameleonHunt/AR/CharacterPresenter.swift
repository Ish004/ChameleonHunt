//
//  CharacterPresenter.swift
//  The hand-painted chameleon of the classic game, in the live AR view.
//
//  A thin layer over one ChameleonActor: it keeps the paint between visits to the studio,
//  follows the hiding spot as ARKit refines it, and exposes the highlight and reveal the
//  screens use. Deciding whether it's hidden, and living camouflage, are the actor's job.
//
//  What's gone: the "render check", which flashed the character pink for three seconds the
//  first time it appeared to prove it rendered, and the per-pixel occluder surface. Both
//  were diagnostics that became part of the experience — the flash and the crawling edge
//  were exactly the kind of flicker that gives a hiding place away.
//

import ARKit
import RealityKit
import SwiftUI
import Combine

@MainActor
final class CharacterPresenter: ObservableObject {

    @Published private(set) var isHighlighted = false
    @Published private(set) var isRevealed = false
    @Published private(set) var visibility: VisibilityPolicy.State = .shown
    @Published private(set) var smoothedCoverage: Float = 0
    /// Real objects in front of the chameleon hide it.
    @Published var occlusionEnabled = true { didSet { actor?.occlusionEnabled = occlusionEnabled } }
    /// How strongly it changes colour to match the room during a hunt (0 = off).
    var livingStrength: Float = 0 { didSet { actor?.livingStrength = livingStrength } }
    /// How far it may borrow the camera's colours on a shiny spot (see ChameleonActor).
    var shineLivingCap: Float = 0.6 { didSet { actor?.shineLivingCap = shineLivingCap } }

    private(set) var actor: ChameleonActor?
    private(set) var geometry: CharacterGeometry?
    private var pixels: [UInt8] = []
    private var placedTransform = matrix_identity_float4x4
    private(set) var lightingGain: Color3 = [1, 1, 1]
    var scale: Float = 1 { didSet { actor?.scale = scale } }

    private let arView: ARView
    private let root: Entity

    init(arView: ARView, root: Entity) {
        self.arView = arView
        self.root = root
    }

    var isShowing: Bool { actor != nil }
    var entity: ModelEntity? { actor?.entity }

    // MARK: - Loading and showing

    /// Takes a paint job for the next time it's shown (or updates the one on show).
    func load(geometry: CharacterGeometry, pixels: [UInt8]) throws {
        let reshaped = self.geometry?.pose != geometry.pose
        self.geometry = geometry
        self.pixels = pixels
        if let actor, !reshaped {
            actor.setPaint(pixels)
        } else if actor != nil {
            show(at: placedTransform)
        }
    }

    func show(at transform: simd_float4x4) {
        actor?.remove()
        actor = nil
        placedTransform = transform
        isRevealed = false
        isHighlighted = false
        guard let geometry, !pixels.isEmpty,
              let actor = try? ChameleonActor(geometry: geometry, paint: pixels, placement: transform,
                                              scale: scale, parent: root) else { return }
        actor.occlusionEnabled = occlusionEnabled
        actor.livingStrength = livingStrength
        actor.shineLivingCap = shineLivingCap
        if simd_reduce_max(abs(lightingGain - Color3(1, 1, 1))) > 0.01 { actor.applyLighting(lightingGain) }
        self.actor = actor
    }

    func hide() {
        actor?.remove()
        actor = nil
        isHighlighted = false
        isRevealed = false
        visibility = .shown
        smoothedCoverage = 0
    }

    var anchorTransform: simd_float4x4 { placedTransform }

    /// Follows ARKit's refinements of the hide anchor. `force` is used by the surface
    /// snap, which applies smaller corrections than the usual threshold.
    func updateAnchor(_ transform: simd_float4x4, force: Bool = false) {
        let delta = transform.columns.3 - placedTransform.columns.3
        let rotationDelta = simd_length(transform.columns.1 - placedTransform.columns.1)
            + simd_length(transform.columns.2 - placedTransform.columns.2)
        guard force || simd_length(delta) > 0.0005 || rotationDelta > 0.001 else { return }
        // Ease into corrections so a snap never looks like a jump.
        var next = transform
        if force { next.columns.3 = placedTransform.columns.3 + (transform.columns.3 - placedTransform.columns.3) * 0.5 }
        placedTransform = next
        actor?.setPlacement(next)
    }

    var characterToWorld: simd_float4x4 {
        placedTransform * simd_float4x4(translation: [0, SurfaceFrame.surfaceOffset, 0]) * simd_float4x4(uniformScale: scale)
    }

    var worldCenter: Vec3? { actor?.worldCenter }

    var isOnScreen: Bool { actor?.isOnScreen(in: arView) ?? false }

    /// True if a world-space ray hits the chameleon (used to keep lighting samples off it).
    func rayHitsCharacter(origin: Vec3, direction: Vec3) -> Bool {
        actor?.hits(origin: origin, direction: direction) ?? false
    }

    /// Re-tints the paint so it matches the room's current exposure.
    func applyLighting(_ gain: Color3) {
        lightingGain = gain
        actor?.applyLighting(gain)
    }

    /// Fed from the AR frame loop.
    func updateVisibility(coverage: Float?, chunkCoverage: [Float?]?, motion: Float, time: TimeInterval) {
        guard let actor else { return }
        actor.updateVisibility(coverage: coverage, chunkCoverage: chunkCoverage, motion: motion, time: time)
        if actor.visibility != visibility { visibility = actor.visibility }
        if abs(actor.smoothedCoverage - smoothedCoverage) > 0.02 { smoothedCoverage = actor.smoothedCoverage }
    }

    // MARK: - Marking

    /// True while it's drawn as a pink marker rather than its paint job.
    var isMarked: Bool { isHighlighted || isRevealed }

    func setMarked(_ marked: Bool) {
        if marked { setHighlighted(true) } else { restore() }
    }

    /// Solid pink and never hidden: shows exactly where it is.
    func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
        actor?.setMarked(highlighted || isRevealed)
    }

    /// Back to the painted look.
    func restore() {
        isHighlighted = false
        isRevealed = false
        actor?.setMarked(false)
    }

    /// End-of-round pop.
    func reveal() {
        isRevealed = true
        actor?.setMarked(true)
        actor?.pop()
    }
}
