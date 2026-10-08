//
//  ScatterStage.swift
//  The "lots of chameleons" game: several of them dropped around the room in a minute,
//  each camouflaging itself, and a seeker trying to find as many as they can.
//
//  Where the classic game is about craft — one chameleon, painted by hand to disappear —
//  this one is about speed and numbers. Nothing is scanned or painted. While aiming you
//  see the chameleon itself, in its own bright colours; drop it and the room's colours
//  wash over it from the feet up (the camera image behind it, and the colour of the spot
//  for the sides it can't see). Then its living camouflage runs flat out while the hider
//  walks around, baking in what it sees from each angle. By the time the iPad is handed
//  over they've all melted into the room, and during the hunt they keep adjusting to
//  whatever the seeker is looking at.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

@MainActor
final class ScatterStage: ObservableObject {

    static let maximum = 10
    /// How far living camouflage may go on a shiny spot (see ChameleonActor.shineLivingCap):
    /// one number for every chameleon, dropped here or by someone else in a squad.
    static let shineLivingCap: Float = 0.95

    @Published private(set) var records: [HiddenChameleon] = []
    @Published private(set) var geometriesReady = false
    private(set) var actors: [ChameleonActor] = []

    private let arView: ARView
    private let root: Entity
    private var geometries: [CharacterPose: CharacterGeometry] = [:]
    private var toyPaint: [CharacterPose: [UInt8]] = [:]
    private var previewModels: [CharacterPose: (mesh: MeshResource, texture: TextureResource)] = [:]
    private let preview = ModelEntity()
    private var previewKey: (pose: CharacterPose, placeable: Bool)?
    private var previewTarget: simd_float4x4?
    /// After a drop the next chameleon waits off stage until this one has blended in,
    /// then hops in — otherwise it lands right on top of the one you're watching melt.
    private var previewHeldUntil = Date.distantPast
    private var previewAppearedAt: Date?
    /// True when the next chameleon is on stage and can be dropped.
    @Published private(set) var previewReady = true
    private var preparing = false
    /// The skin the toy colours were made in (the player's, from the wallet).
    private var paintedSkin: ChameleonSkin?

    init(arView: ARView, root: Entity) {
        self.arView = arView
        self.root = root
        preview.isEnabled = false
        root.addChild(preview)
    }

    var count: Int { records.count }
    var foundCount: Int { records.filter(\.isFound).count }
    var remaining: Int { count - foundCount }

    /// Builds every pose's geometry in the background, once, and paints each in the
    /// player's skin: what follows the aim, and what lands before the room's colours wash
    /// over it. If the skin has changed since, only the paint is redone.
    func prepare() {
        let skin = Wallet.shared.skin
        guard !preparing else { return }
        guard geometries.count < CharacterPose.allCases.count else {
            if skin != paintedSkin { repaint(in: skin) }
            return
        }
        preparing = true
        paintedSkin = skin
        Task {
            let palette = skin.palette
            let built = await Task.detached(priority: .userInitiated) {
                CharacterPose.allCases.map { pose in
                    let geometry = CharacterGeometry.build(from: CharacterShape.build(pose), cellPixels: 5)
                    return (pose, geometry, ToyPaint.pixels(for: geometry, palette: palette))
                }
            }.value
            for (pose, geometry, paint) in built {
                geometries[pose] = geometry
                toyPaint[pose] = paint
                // Drawn the way a dropped one is (DisplayCurve), so it doesn't change shade
                // as it leaves the aim and lands.
                if let mesh = try? SceneAssets.mesh(geometry.render, name: "preview-\(pose.rawValue)"),
                   let texture = try? SceneAssets.staticTexture(rgba: SceneAssets.displayCurve.apply(paint),
                                                                width: geometry.atlasWidth, height: geometry.atlasHeight) {
                    previewModels[pose] = (mesh, texture)
                }
            }
            geometriesReady = true
            preparing = false
        }
    }

    /// The player's wearing a different skin: the toy colours are made again in it.
    private func repaint(in skin: ChameleonSkin) {
        preparing = true
        paintedSkin = skin
        let shapes = geometries
        Task {
            let palette = skin.palette
            let painted = await Task.detached(priority: .userInitiated) {
                shapes.mapValues { ToyPaint.pixels(for: $0, palette: palette) }
            }.value
            for (pose, paint) in painted { toyPaint[pose] = paint }
            redrawPreview()
            preparing = false
        }
    }

    /// The display curve changed (a new measurement): the aim preview is stored afresh,
    /// like every dropped chameleon.
    func redrawPreview() {
        for (pose, model) in previewModels {
            guard let geometry = geometries[pose], let paint = toyPaint[pose],
                  let image = try? SceneAssets.image(rgba: SceneAssets.displayCurve.apply(paint),
                                                     width: geometry.atlasWidth, height: geometry.atlasHeight) else { continue }
            try? model.texture.replace(withImage: image, options: .init(semantic: .color, mipmapsMode: .none))
        }
    }

    /// The bright chameleon that follows the aim point while hiding them.
    /// - Parameter transform: character-to-world, or nil to hide it.
    func showPreview(pose: CharacterPose, transform: simd_float4x4?, placeable: Bool) {
        guard let transform, let model = previewModels[pose] else {
            preview.isEnabled = false
            previewTarget = nil
            return
        }
        if previewKey?.pose != pose || previewKey?.placeable != placeable {
            var material = SceneAssets.camouflage(model.texture)
            if !placeable { material.blending = .transparent(opacity: .init(floatLiteral: 0.4)) }
            preview.model = ModelComponent(mesh: model.mesh, materials: [material])
            previewKey = (pose, placeable)
        }
        previewTarget = transform
        animatePreview()
    }

    /// Every frame while hiding: keeps the preview off stage during the hold, then pops
    /// it in with a little overshoot.
    func animatePreview() {
        guard let target = previewTarget else { return }
        let now = Date()
        guard now >= previewHeldUntil else {
            preview.isEnabled = false
            previewAppearedAt = nil
            if previewReady { previewReady = false }
            return
        }
        let appeared = previewAppearedAt ?? now
        previewAppearedAt = appeared
        let t = Float(min(now.timeIntervalSince(appeared) / 0.32, 1))
        // Ease out with a small overshoot, like something hopping into place.
        let s: Float = 1.7, u = t - 1
        let grow = max(0.01, 1 + (s + 1) * u * u * u + s * u * u)
        preview.transform = Transform(matrix: target * simd_float4x4(uniformScale: grow))
        preview.isEnabled = true
        if !previewReady { previewReady = true }
    }

    /// Drops one at `placement`. It lands in its own colours, then melts into the room:
    /// `colour` is what the spot looks like, and `frame` (the camera, right now) gives
    /// the parts of it facing the camera exactly what's behind them.
    @discardableResult
    func drop(pose: CharacterPose, scale: Float, placement: simd_float4x4, colour: Color3,
              frame: LiveFrameSnapshot?, id: UUID = UUID(), owner: Player = .local) -> Bool {
        let mine = records.filter { $0.hiddenBy.id == owner.id }.count
        guard mine < Self.maximum, let geometry = geometries[pose], let toy = toyPaint[pose] else { return false }

        let record = HiddenChameleon(id: id, hiddenBy: owner, pose: pose, scale: scale, transform: placement)
        guard let actor = try? ChameleonActor(id: record.id, geometry: geometry, paint: toy,
                                              placement: placement, scale: scale, parent: root) else { return false }
        // While hiding, learn the room as fast as possible and keep what's learned.
        actor.livingStrength = 1
        actor.livingIsPermanent = true
        actor.shineLivingCap = Self.shineLivingCap
        actor.pop(amount: 1.2)
        actor.owner = owner.id
        actors.append(actor)
        records.append(record)
        previewHeldUntil = Date().addingTimeInterval(1.9)
        preview.isEnabled = false
        previewReady = false

        let characterToWorld = actor.characterToWorld
        Task {
            let target = await Task.detached(priority: .userInitiated) {
                Self.camouflage(geometry: geometry, spot: colour, frame: frame?.keyframe(),
                                characterToWorld: characterToWorld)
            }.value
            // Let it land first.
            try? await Task.sleep(for: .milliseconds(250))
            await actor.melt(into: target)
        }
        return true
    }

    /// What it should end up looking like: the spot's colour everywhere, and the camera
    /// image behind it wherever the camera can see it.
    nonisolated private static func camouflage(geometry: CharacterGeometry, spot: Color3, frame: Keyframe?,
                                               characterToWorld: simd_float4x4) -> [UInt8] {
        let (r, g, b) = packRGBA(spot)
        var flat = [UInt8](repeating: 255, count: geometry.atlasWidth * geometry.atlasHeight * 4)
        for i in stride(from: 0, to: flat.count, by: 4) { flat[i] = r; flat[i + 1] = g; flat[i + 2] = b }
        guard let frame else { return flat }
        let skin = LiveSkin(geometry: geometry, base: flat)
        var settings = LiveSkin.Settings()
        settings.strength = 1
        settings.adaptRate = 1
        skin.update(from: frame, characterToWorld: characterToWorld, settings: settings)
        return skin.composed
    }

    func undo() {
        previewHeldUntil = .distantPast
        guard let actor = actors.popLast() else { return }
        actor.remove()
        records.removeLast()
    }

    func clear() {
        preview.isEnabled = false
        previewHeldUntil = .distantPast
        for actor in actors { actor.remove() }
        actors.removeAll()
        records.removeAll()
    }

    /// Fixes each one's camouflage as it is now, then lets it keep adapting during the
    /// hunt at the round's strength.
    func prepareForHunt(livingStrength: Float) {
        for actor in actors {
            actor.commitLivingToPaint()
            actor.livingIsPermanent = false
            actor.livingStrength = livingStrength
            actor.setMarked(false)
            actor.isFound = false
        }
        for index in records.indices {
            records[index].foundBy = nil
            records[index].foundAfter = nil
        }
    }

    /// Back from the handoff screen to hide more: learning at full speed again.
    func resumeHiding() {
        for actor in actors {
            actor.livingStrength = 1
            actor.livingIsPermanent = true
            actor.setMarked(false)
            // Any found in a hunt that was abandoned are hidden again.
            actor.isFound = false
        }
        for index in records.indices {
            records[index].foundBy = nil
            records[index].foundAfter = nil
        }
    }

    // MARK: - Squad play

    /// Someone else's chameleon, placed where their anchor landed in this device's room.
    /// It starts a plain mid-grey and hidden; its real paint arrives with the hunt.
    @discardableResult
    func addRemote(id: UUID, owner: UUID, pose: CharacterPose, scale: Float, placement: simd_float4x4,
                   livingStrength: Float) -> Bool {
        guard !actors.contains(where: { $0.id == id }), let geometry = geometries[pose] else { return false }
        let grey = [UInt8](repeating: 140, count: geometry.atlasWidth * geometry.atlasHeight * 4)
        let record = HiddenChameleon(id: id, hiddenBy: Player(id: owner, name: ""), pose: pose, scale: scale,
                                     transform: placement)
        guard let actor = try? ChameleonActor(id: id, geometry: geometry, paint: grey, placement: placement,
                                              scale: scale, parent: root) else { return false }
        actor.owner = owner
        actor.suppressed = true
        actor.livingStrength = livingStrength
        actor.livingIsPermanent = false
        // On glass and gloss it borrows more of the live picture, exactly as one dropped
        // on this device does (drop): hidden the same whoever's device hid it.
        actor.shineLivingCap = Self.shineLivingCap
        actors.append(actor)
        records.append(record)
        return true
    }

    func actor(_ id: UUID) -> ChameleonActor? { actors.first { $0.id == id } }

    func move(_ id: UUID, to placement: simd_float4x4) {
        actor(id)?.setPlacement(placement)
    }

    func remove(_ id: UUID) {
        guard let index = actors.firstIndex(where: { $0.id == id }) else { return }
        actors[index].remove()
        actors.remove(at: index)
        records.removeAll { $0.id == id }
    }

    /// Marks one found (by anyone), in the finder's colour. If the host gives it to
    /// someone else (they tapped first), it changes to theirs.
    func markFound(_ id: UUID, colour: UIColor = .systemPink) {
        guard let actor = actor(id) else { return }
        guard !actor.isFound else {
            actor.setMarked(true, colour: colour)
            return
        }
        actor.suppressed = false
        actor.shownAsMine = false
        actor.isFound = true
        actor.setMarked(true, colour: colour)
        actor.pop(amount: 1.5)
    }

    /// The camouflage as it is now, small enough to send: a JPEG of the paint atlas.
    func skinJPEG(_ id: UUID) -> Data? {
        guard let actor = actor(id),
              let image = try? SceneAssets.image(rgba: actor.skin.composed, width: actor.geometry.atlasWidth,
                                                 height: actor.geometry.atlasHeight) else { return nil }
        // Half size: it's sent to every device as the hunt starts, and it keeps adapting
        // to the room there anyway.
        let half = CGSize(width: image.width / 2, height: image.height / 2)
        let small = UIGraphicsImageRenderer(size: half, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { _ in UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: half)) }
        return small.jpegData(compressionQuality: 0.6)
    }

    /// Paints someone else's chameleon the way it looked where it was hidden.
    func applySkin(_ id: UUID, jpeg: Data) {
        guard let actor = actor(id), let image = UIImage(data: jpeg)?.cgImage else { return }
        let width = actor.geometry.atlasWidth, height = actor.geometry.atlasHeight
        // Sent at half size; drawn back up to the chameleon's own size.
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if drawn { actor.setPaint(pixels) }
    }

    /// The first unfound chameleon any of these screen points lands on.
    /// `reach`: how many points from the tap still count (less at harder difficulties).
    func unfoundActor(near point: CGPoint, reach: CGFloat = 26) -> ChameleonActor? {
        unfoundActor(near: point, excludingOwner: nil, reach: reach)
    }

    /// Whether these screen points land on one that's lit up or marked as the player's own
    /// (found, revealed, or "Yours"): a tap there isn't a miss.
    func touchesLitUp(near point: CGPoint, reach: CGFloat = 26) -> Bool {
        var probes = [point]
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            probes.append(CGPoint(x: point.x + cos(angle) * reach, y: point.y + sin(angle) * reach))
        }
        for probe in probes {
            guard let ray = arView.ray(through: probe) else { continue }
            let direction = simd_normalize(ray.direction)
            if actors.contains(where: { ($0.isMarked || $0.shownAsMine) && !$0.suppressed
                                        && $0.hits(origin: ray.origin, direction: direction) }) { return true }
        }
        return false
    }

    /// Same, skipping the player's own and any not being shown.
    func unfoundActor(near point: CGPoint, excludingOwner owner: UUID?, reach: CGFloat = 26) -> ChameleonActor? {
        var probes = [point]
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            probes.append(CGPoint(x: point.x + cos(angle) * reach, y: point.y + sin(angle) * reach))
        }
        for probe in probes {
            guard let ray = arView.ray(through: probe) else { continue }
            let direction = simd_normalize(ray.direction)
            // Nearest first, so a tap takes the one in front.
            let hits = actors.filter {
                !$0.isFound && !$0.suppressed && (owner == nil || $0.owner != owner)
                    && $0.hits(origin: ray.origin, direction: direction)
            }
            if let nearest = hits.min(by: { simd_distance($0.worldCenter, ray.origin) < simd_distance($1.worldCenter, ray.origin) }) {
                return nearest
            }
        }
        return nil
    }

    func markFound(_ actor: ChameleonActor, after seconds: TimeInterval) {
        guard !actor.isFound, let index = records.firstIndex(where: { $0.id == actor.id }) else { return }
        actor.isFound = true
        actor.setMarked(true)
        actor.pop(amount: 1.5)
        records[index].foundBy = .local
        records[index].foundAfter = seconds
    }

    /// End of round: the ones nobody found light up — pink, or in a squad game the
    /// colour of whoever hid each one (it's their point).
    /// `excludingOwner`: leave that player's own as they are (someone who gave up sees
    /// where the rest are, not their own lit up).
    func revealUnfound(excludingOwner owner: UUID? = nil, colour: (ChameleonActor) -> UIColor = { _ in .systemPink }) {
        for actor in actors where !actor.isFound && (owner == nil || actor.owner != owner) {
            let wasMarked = actor.isMarked
            actor.suppressed = false
            actor.shownAsMine = false
            actor.setMarked(true, colour: colour(actor))
            if !wasMarked { actor.pop() }
        }
    }

    /// For the "this way" arrow: the nearest one that's still worth pointing at — not one
    /// of the player's own in a squad game, and not one that isn't out yet.
    func nearestUnfound(to position: Vec3, excludingOwner owner: UUID? = nil) -> ChameleonActor? {
        actors.filter { !$0.isFound && !$0.suppressed && (owner == nil || $0.owner != owner) }
            .min { simd_distance($0.worldCenter, position) < simd_distance($1.worldCenter, position) }
    }

    #if DEBUG
    /// Records without chameleons in the room, for laying out the screens in the Simulator.
    func debugFill(count: Int, found: Int) {
        clear()
        for index in 0..<count {
            var record = HiddenChameleon(pose: .standing, scale: 1, transform: matrix_identity_float4x4)
            if index < found { record.foundBy = .local; record.foundAfter = Double(index * 11 + 7) }
            records.append(record)
        }
    }
    #endif
}
