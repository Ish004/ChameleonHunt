//
//  ChameleonActor.swift
//  One chameleon in the room: its model, its paint, its living camouflage, and its own
//  decision about whether it's currently behind something.
//
//  Everything that used to be welded into a single "the character" now lives here, so the
//  classic game (one chameleon, painted by hand) and the new one (a handful of them,
//  camouflaging themselves) are the same code with a different number of these.
//

import ARKit
import RealityKit
import SwiftUI

@MainActor
final class ChameleonActor {

    let id: UUID
    let geometry: CharacterGeometry
    /// Holds the whole-chameleon fade; its children are the chunks (see ChameleonChunks).
    let entity = ModelEntity()
    let skin: LiveSkin

    let chunks: ChameleonChunks
    private var chunkEntities: [ModelEntity] = []
    private var chunkVisibility: ChunkVisibility
    private var texture: TextureResource?
    private weak var root: Entity?

    private(set) var placement: simd_float4x4
    var scale: Float { didSet { applyTransform() } }

    /// 0 turns living camouflage off; otherwise the most live colour allowed to show.
    var livingStrength: Float = 0
    /// How far living camouflage may go on a shiny spot, even when it's otherwise off.
    /// Glass, mirrors and gloss show a different reflection from every angle, which no
    /// paint job can follow; there the chameleon borrows a little of what the camera sees,
    /// more the shinier the spot, but never so much that the paint stops mattering.
    var shineLivingCap: Float = 0
    /// How shiny the surface behind it looks to the depth sensor, smoothed (0…1).
    private(set) var shine: Float = 0
    /// How much the surface behind it disagrees with the scan (LightingMatch), 0…1.
    var viewDependence: Float = 0

    /// What living camouflage actually runs at: its own strength, or more on a shiny spot.
    /// Two signals say "shiny": the depth sensor being unsure of the surface, and the
    /// surface not looking the way the scan recorded it. The stronger one wins.
    var effectiveLivingStrength: Float {
        let unsure = min(max((shine - 0.12) / 0.4, 0), 1)
        return max(livingStrength * camouflageScale, shineLivingCap * max(unsure, viewDependence))
    }
    /// While hiding in the "lots of them" game, what the hider's camera sees is baked in
    /// for good rather than slowly forgotten.
    var livingIsPermanent = false
    private(set) var isRefreshingSkin = false

    private var policy = VisibilityPolicy()
    private(set) var coverage: Float = 0
    /// Real objects in front of it hide it.
    var occlusionEnabled = true

    /// Out in the open (found, shown at the end of a round, highlighted) rather than hiding.
    private(set) var isMarked = false
    private var markColour: UIColor = .systemPink
    var isFound = false
    /// What it looks like as itself: the toy in its hider's skin (ToyPaint), the one that
    /// followed their aim and landed. Out in the open it goes back to this, with a rim
    /// in the colour of whoever got its point. (Until v7.6 it turned that colour all
    /// over, which read as an overlay stuck on the room rather than a chameleon.)
    /// Without one, as for the hand-painted chameleon in Paint & Hide, it lights up
    /// solid instead.
    var ownLook: [UInt8]? {
        didSet {
            guard isMarked else { return }
            applyMaterial()
            uploadSkin()
        }
    }
    /// The rim round it while it's out in the open in its own colours: a thin ink line
    /// against the chameleon, then the colour, like every sticker in the game.
    private var outline: Entity?
    private var outlineColour: ModelEntity?
    private var wearsOwnLook: Bool { isMarked && texture != nil && ownLook?.count == paint.count }
    /// Squad play: who hid it.
    var owner: UUID?
    /// Squad play: not shown at all (someone else's, while they're still hiding).
    var suppressed = false { didSet { currentOpacity = -1 } }
    /// Squad play: one of your own during the hunt, shown only if you asked to see them:
    /// a see-through white chameleon, plainly not a find and not one to hunt. (Shown
    /// faintly in its camouflage, as it was until v6.9, players kept tapping their own.)
    var shownAsMine = false {
        didSet {
            guard shownAsMine != oldValue else { return }
            applyMaterial()
            currentOpacity = -1
        }
    }
    /// What its living camouflage strength is multiplied by right now: a little less
    /// close up and across a big space (RoomSpread). Set every frame during a hunt.
    var camouflageScale: Float = 1
    /// How fast it catches up with a new view (LiveSkin.Settings.adaptRate): the hunt's
    /// difficulty sets it.
    var livingAdaptRate: Float = 0.45
    /// How far its colours are drawn off a perfect match right now (HuntDifficulty.tell):
    /// nothing while hiding, a little during a hunt, more right next to it.
    var tell: Float = 0
    /// How much of it the seeker gets to see right now, on top of everything else: less
    /// the further away they are (DistanceFade), and none while tracking is lost (so it's
    /// never seen in the wrong place). Set every frame by the session controller.
    var viewFade: Float = 1

    /// The paint as painted, before the room's lighting is applied.
    private var paint: [UInt8]
    private var lightingGain: Color3 = [1, 1, 1]

    init(id: UUID = UUID(), geometry: CharacterGeometry, paint: [UInt8], placement: simd_float4x4,
         scale: Float, parent: Entity) throws {
        self.id = id
        self.geometry = geometry
        self.paint = paint
        self.placement = placement
        self.scale = scale
        root = parent
        let pieces = try Self.chunkMeshes(for: geometry)
        chunks = pieces.chunks
        chunkVisibility = ChunkVisibility(count: pieces.chunks.count)
        texture = try? SceneAssets.staticTexture(rgba: SceneAssets.displayCurve.apply(paint),
                                                 width: geometry.atlasWidth, height: geometry.atlasHeight)
        skin = LiveSkin(geometry: geometry, base: paint)
        entity.name = "chameleon-\(id.uuidString.prefix(6))"
        for mesh in pieces.meshes {
            let chunk = ModelEntity()
            chunk.model = ModelComponent(mesh: mesh, materials: [])
            entity.addChild(chunk)
            chunkEntities.append(chunk)
        }
        parent.addChild(entity)
        applyMaterial()
        applyTransform()
        setOpacity(1)
    }

    func remove() {
        entity.removeFromParent()
    }

    /// Chunk meshes are the same for every chameleon in a pose, so they're built once.
    private static var chunkCache: [String: (chunks: ChameleonChunks, meshes: [MeshResource])] = [:]

    private static func chunkMeshes(for geometry: CharacterGeometry) throws -> (chunks: ChameleonChunks, meshes: [MeshResource]) {
        let key = "\(geometry.pose.rawValue)-\(geometry.atlasWidth)x\(geometry.atlasHeight)"
        if let cached = chunkCache[key] { return cached }
        let chunks = ChameleonChunks.build(geometry)
        let meshes = try chunks.chunks.enumerated().map { index, chunk in
            try SceneAssets.mesh(chunk.buffers, name: "chameleon-\(key)-\(index)")
        }
        chunkCache[key] = (chunks, meshes)
        return (chunks, meshes)
    }

    // MARK: - Where it is

    var characterToWorld: simd_float4x4 {
        placement * simd_float4x4(translation: [0, SurfaceFrame.surfaceOffset, 0]) * simd_float4x4(uniformScale: scale)
    }

    func setPlacement(_ transform: simd_float4x4) {
        placement = transform
        applyTransform()
    }

    private func applyTransform() {
        entity.transform = Transform(matrix: characterToWorld)
    }

    var worldCenter: Vec3 {
        characterToWorld.transformPoint((geometry.boundsMin + geometry.boundsMax) * 0.5)
    }

    func isOnScreen(in arView: ARView) -> Bool {
        guard let point = arView.project(worldCenter) else { return false }
        return arView.bounds.insetBy(dx: -80, dy: -80).contains(point)
    }

    /// Does a world-space ray hit it?
    func hits(origin: Vec3, direction: Vec3) -> Bool {
        let toCharacter = characterToWorld.inverse
        return geometry.bvh.intersect(origin: toCharacter.transformPoint(origin),
                                      direction: simd_normalize(toCharacter.transformDirection(direction))) != nil
    }

    // MARK: - Paint

    /// A new paint job, e.g. back from the studio.
    func setPaint(_ pixels: [UInt8]) {
        guard pixels.count == paint.count else { return }
        paint = pixels
        skin.clear()
        applyLighting(lightingGain)
    }

    /// Re-tints the paint so it matches the room's current exposure (see LightingMatch).
    func applyLighting(_ gain: Color3) {
        lightingGain = gain
        if simd_reduce_max(abs(gain - Color3(1, 1, 1))) < 0.005 {
            skin.setBase(paint)
        } else {
            let table = LightingEstimate.lookupTable(gain: gain)
            var tinted = paint
            for i in stride(from: 0, to: tinted.count, by: 4) {
                tinted[i] = table[Int(paint[i])]
                tinted[i + 1] = table[256 + Int(paint[i + 1])]
                tinted[i + 2] = table[512 + Int(paint[i + 2])]
            }
            skin.setBase(tinted)
        }
        uploadSkin()
    }

    /// True while it's changing from its own colours into the room's (see `melt`).
    private(set) var isMelting = false

    /// The moment a dropped chameleon disappears: its own colours give way to the room's
    /// as a wave rising from where it stands, with a faint bright edge where the change
    /// is happening — the way a chameleon's colour seems to flow over it.
    func melt(into target: [UInt8], duration: TimeInterval = 1.3) async {
        guard target.count == paint.count, !isMelting else { return }
        isMelting = true
        let from = paint
        let texels = geometry.validTexels
        let lo = geometry.boundsMin.y
        let span = max(geometry.boundsMax.y - lo, 1e-4)
        let heights = texels.map { (geometry.texelPositions[Int($0)].y - lo) / span }
        var frame = from
        let start = Date()
        while entity.parent != nil {
            let t = Float(min(Date().timeIntervalSince(start) / duration, 1))
            // The wave starts just below the feet and finishes just above the head.
            let wave = -0.3 + t * 1.6
            for k in texels.indices {
                let i = Int(texels[k]) * 4
                let f = min(max((wave - heights[k]) / 0.3, 0), 1)
                let eased = f * f * (3 - 2 * f)
                let glow = 4 * f * (1 - f) * 0.3
                for c in 0..<3 {
                    let a = Float(from[i + c]), b = Float(target[i + c])
                    let mixed = a + (b - a) * eased
                    frame[i + c] = UInt8(min(255, max(0, mixed + (255 - mixed) * glow)))
                }
            }
            paint = frame
            applyLighting(lightingGain)
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        paint = target
        applyLighting(lightingGain)
        isMelting = false
    }

    /// Makes what the living camouflage has learned part of the paint for good — used
    /// when the hider hands over in the "lots of them" game.
    func commitLivingToPaint() {
        // The paint is the match itself, without any tell from a hunt just played.
        skin.setTell(0)
        paint = skin.composed
        skin.setBase(paint)
        skin.clear()
        uploadSkin()
    }

    private func uploadSkin() {
        // Out in the open it's in its own colours, not the room's; lit up solid, its
        // texture isn't on show at all.
        guard !isMarked || wearsOwnLook else { return }
        let pixels = (isMarked ? ownLook : nil) ?? skin.composed
        // What's stored isn't what's wanted on screen but what shows as it (DisplayCurve).
        if let image = try? SceneAssets.image(rgba: SceneAssets.displayCurve.apply(pixels),
                                              width: geometry.atlasWidth, height: geometry.atlasHeight) {
            try? texture?.replace(withImage: image, options: .init(semantic: .color, mipmapsMode: .none))
        }
    }

    /// The display curve changed (a new measurement): store its colours afresh.
    func redraw() {
        uploadSkin()
    }

    private func applyMaterial() {
        let material: RealityKit.Material
        if isMarked, !wearsOwnLook {
            material = SceneAssets.reveal(markColour)
        } else if shownAsMine, !isMarked {
            material = SceneAssets.mine
        } else if let texture {
            material = SceneAssets.camouflage(texture)
        } else {
            material = SceneAssets.flat(SceneAssets.averageColor(rgba: skin.composed, texels: geometry.validTexels))
        }
        for chunk in chunkEntities {
            chunk.model?.materials = [material]
        }
        applyOutline()
    }

    /// How far the rim reaches from the chameleon, and how much of that is the ink line
    /// next to it, in the chameleon's own metres (it's about 30 cm long). The line keeps
    /// the rim plain to see when it's the chameleon's own colour: a pink rim on a
    /// bubblegum skin, a yellow one on a lemon.
    static let outlineWidth: Float = 0.009
    static let outlineInk: Float = 0.003

    /// The rim's shapes: the chameleon's own, that much bigger all round (OutlineHull),
    /// to be drawn inside out (SceneAssets.outline). The chameleon covers all of each
    /// but the part that sticks out past its edge, and the ink one covers the coloured
    /// one as far as it reaches. One pair per pose, like the chunks.
    private static var outlineCache: [String: (ink: MeshResource, colour: MeshResource)] = [:]

    private static func outlineMeshes(for geometry: CharacterGeometry) throws -> (ink: MeshResource, colour: MeshResource) {
        let key = "\(geometry.pose.rawValue)-\(geometry.atlasWidth)x\(geometry.atlasHeight)"
        if let cached = outlineCache[key] { return cached }
        // Straight across the pupils' sockets, or a fleck of rim shows on each pupil.
        let pupils = geometry.eyes.map { OutlineHull.Socket(centre: $0.centre, radius: $0.radius, look: $0.look) }
        let meshes = (ink: try SceneAssets.mesh(OutlineHull.expand(geometry.render, by: outlineInk, bridging: pupils),
                                                name: "outline-ink-\(key)"),
                      colour: try SceneAssets.mesh(OutlineHull.expand(geometry.render, by: outlineWidth, bridging: pupils),
                                                   name: "outline-\(key)"))
        outlineCache[key] = meshes
        return meshes
    }

    private func applyOutline() {
        guard wearsOwnLook else {
            outline?.isEnabled = false
            return
        }
        if outline == nil, let meshes = try? Self.outlineMeshes(for: geometry) {
            let rim = Entity()
            rim.name = "outline"
            let ink = ModelEntity()
            ink.model = ModelComponent(mesh: meshes.ink, materials: [SceneAssets.outline(UIColor(Hunt.ink))])
            let colour = ModelEntity()
            colour.model = ModelComponent(mesh: meshes.colour, materials: [])
            rim.addChild(ink)
            rim.addChild(colour)
            entity.addChild(rim)
            outline = rim
            outlineColour = colour
        }
        outlineColour?.model?.materials = [SceneAssets.outline(markColour)]
        outline?.isEnabled = showsOutline(at: currentOpacity)
    }

    /// The rim is for a chameleon that's solidly there. While it fades (tracking lost
    /// and found again) the rim's far side would show through it, tinting all of it the
    /// rim's colour, so the rim waits until the fade is over.
    private func showsOutline(at opacity: Float) -> Bool { wearsOwnLook && opacity >= 1 }

    // MARK: - Living camouflage

    /// One step of changing colour to match what's behind it, from a camera frame.
    func refreshLiving(from frame: Keyframe) async {
        let strength = effectiveLivingStrength
        guard strength > 0.02, !isRefreshingSkin, !isMarked, !isMelting else { return }
        isRefreshingSkin = true
        let skin = self.skin
        let transform = characterToWorld
        var settings = LiveSkin.Settings()
        settings.strength = strength
        settings.forgetRate = livingIsPermanent ? 0 : 0.02
        // While hiding it learns at its usual pace and is drawn as it is; the hunt's
        // difficulty sets both from then on.
        settings.adaptRate = livingIsPermanent ? LiveSkin.Settings().adaptRate : livingAdaptRate
        settings.tell = livingIsPermanent ? 0 : tell
        _ = await Task.detached(priority: .userInitiated) {
            skin.update(from: frame, characterToWorld: transform, settings: settings)
        }.value
        isRefreshingSkin = false
        uploadSkin()
    }

    // MARK: - Showing and hiding

    /// Feeds in how much of it is behind real things: the whole-chameleon share, and
    /// per chunk (nil when there's no fresh reading this frame — fades still advance).
    func updateVisibility(coverage: Float?, chunkCoverage: [Float?]?, motion: Float, time: TimeInterval) {
        if let coverage { self.coverage = coverage }
        guard occlusionEnabled, !isMarked else {
            policy.reset()
            chunkVisibility.reset()
            setOpacity(1)
            setChunkOpacities(chunkVisibility.opacity)
            return
        }
        if let chunkCoverage {
            chunkVisibility.update(coverage: chunkCoverage, neighbours: chunks.chunks.map(\.neighbours),
                                   motion: motion, timestamp: time)
        }
        setChunkOpacities(chunkVisibility.advance(to: time))
        setOpacity(policy.update(coverage: self.coverage, motion: motion, timestamp: time))
    }

    /// How many chunks are faded out right now (diagnostics).
    var hiddenChunkCount: Int { chunkVisibility.hiddenCount }

    /// A reading of how unsure the depth sensor is about the surface behind it.
    func noteShine(_ unsure: Float) {
        shine += (unsure - shine) * 0.08
    }

    private var chunkOpacity: [Float] = []
    private func setChunkOpacities(_ values: [Float]) {
        if chunkOpacity.count != values.count { chunkOpacity = [Float](repeating: -1, count: values.count) }
        for i in values.indices where abs(values[i] - chunkOpacity[i]) > 0.004 {
            chunkOpacity[i] = values[i]
            chunkEntities[i].isEnabled = values[i] > 0.01
            if values[i] >= 0.999 {
                chunkEntities[i].components.remove(OpacityComponent.self)
            } else {
                chunkEntities[i].components.set(OpacityComponent(opacity: values[i]))
            }
        }
    }

    var visibility: VisibilityPolicy.State { policy.state }
    var smoothedCoverage: Float { policy.smoothedCoverage }

    private var currentOpacity: Float = -1
    private func setOpacity(_ requested: Float) {
        var value = suppressed ? 0 : requested * (shownAsMine && !isMarked ? 0.5 : 1) * viewFade
        // A fade creeps up on 1 without arriving: close enough is all the way, so that
        // it's drawn as a solid thing again (and its rim comes back).
        if value > 0.995 { value = 1 }
        guard abs(value - currentOpacity) > 0.004 || (value == 1) != (currentOpacity == 1) else { return }
        currentOpacity = value
        entity.isEnabled = value > 0.01
        entity.components.set(OpacityComponent(opacity: value))
        outline?.isEnabled = showsOutline(at: value)
    }

    // MARK: - Marking

    /// Brings it out into the open, or sends it back into hiding. `colour` is its rim
    /// (who got its point: in squad play the finder's, or the hider's if nobody found
    /// it), or all of it where it has no look of its own. It can change while marked (the
    /// host gives a find to whoever tapped first).
    func setMarked(_ marked: Bool, colour: UIColor = .systemPink) {
        guard marked != isMarked || (marked && colour != markColour) else { return }
        let wasMarked = isMarked
        isMarked = marked
        markColour = colour
        applyMaterial()
        if marked && wasMarked { return }
        if marked {
            chunkVisibility.reset()
            setChunkOpacities(chunkVisibility.opacity)
            setOpacity(1)
        }
        // Its own colours as it comes out; the room's again as it goes back.
        uploadSkin()
    }

    /// A little bounce — dropped in, found, or revealed.
    func pop(amount: Float = 1.35) {
        guard let root else { return }
        let base = Transform(matrix: characterToWorld)
        var puffed = base
        puffed.scale *= amount
        entity.move(to: puffed, relativeTo: root, duration: 0.18, timingFunction: .easeOut)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.2))
            guard let self, let root = self.root else { return }
            self.entity.move(to: Transform(matrix: self.characterToWorld), relativeTo: root,
                             duration: 0.22, timingFunction: .easeInOut)
        }
    }
}
