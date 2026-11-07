//
//  StudioController.swift
//  The 3D paint studio: the extracted room chunk and the character in a virtual
//  (non-AR) view you can spin around, with the brush tools that paint the character.
//
//  Spaces:
//   - World: the studio scene is laid out in ARKit world orientation, so up is up
//     for both floor and wall hiding spots and orbiting feels natural.
//   - Anchor: the hide-anchor frame (environment triangles live here).
//   - Character: anchor space minus the surface offset, divided by the size scale
//     (texel positions live here).
//

import Combine
import RealityKit
import SwiftUI
import UIKit

@MainActor
final class StudioController: ObservableObject {

    enum Tool: String, CaseIterable, Identifiable {
        case brush
        case camo
        case eyedropper

        var id: String { rawValue }

        var title: String {
            switch self {
            case .brush: return "Paint"
            case .camo: return "Copy room"
            case .eyedropper: return "Pick colour"
            }
        }

        var systemImage: String {
            switch self {
            case .brush: return "paintbrush.pointed.fill"
            case .camo: return "square.on.square.dashed"
            case .eyedropper: return "eyedropper.halffull"
            }
        }

        /// What it does, said the way you'd explain it to someone looking over your shoulder.
        var hint: String {
            switch self {
            case .brush: return "Paint on the chameleon"
            case .camo: return "Paints on what's behind it, from here"
            case .eyedropper: return "Tap the room to pick a colour"
            }
        }
    }

    // MARK: Published state

    @Published var tool: Tool = .brush
    @Published var color: Color3 = [0.62, 0.70, 0.60]
    @Published private(set) var recentColors: [Color3] = []
    @Published var brushSizeCentimeters: Float = 1.5
    @Published var opacity: Float = 0.9
    @Published var hardness: Float = 0.4
    @Published var showEnvironment = true { didSet { environmentEntity.isEnabled = showEnvironment } }
    @Published var shapeShading = false { didSet { applyCharacterMaterial() } }
    @Published var characterScale: Float { didSet { applyCharacterTransform() } }
    @Published private(set) var pose: CharacterPose
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var busyMessage: String?
    @Published private(set) var busyProgress: Float = 0
    @Published private(set) var pencilDetected = false
    /// One finger paints and two turn the model. On by default because most people
    /// holding this iPad won't have a Pencil; the moment a Pencil touches the screen it
    /// takes over painting and fingers go back to moving the view.
    @Published var fingerPaints = true { didSet { input.setFingerPaints(fingerPaints) } }

    let scene: HideScene
    let arView: ARView
    private(set) var canvas: PaintCanvas
    private(set) var characterTexture: LiveTexture

    // MARK: Scene graph

    private let root = AnchorEntity(world: .zero)
    private let sceneFrame = Entity()          // world <- anchor
    private let environmentEntity = ModelEntity()
    private let characterEntity = ModelEntity()
    private let camera = PerspectiveCamera()
    private let light = DirectionalLight()
    private var environmentTexture: LiveTexture?
    private let input = StudioInputHandler()

    // MARK: Camera

    private static let verticalFieldOfView: Float = 50
    private var orbitTarget: Vec3 = .zero
    private var azimuth: Float = 0
    private var elevation: Float = 0.35
    private var distance: Float = 0.9
    private var cameraPosition: Vec3 = .zero

    // MARK: Painting state

    private var lastDabPoint: Vec3?
    private var toolBeforeEyedropper: Tool?

    // Per-stroke caches. Both depend only on the viewpoint, so they're rebuilt when the
    // view changes rather than recomputed for every texel of every dab.
    private var strokeVisibility: VisibilityMap?
    private var visibilityIsStale = true
    private var camoColors: [Color3] = []
    private var camoStamps: [UInt32] = []
    private var camoStamp: UInt32 = 0

    /// - Parameter initialPixels: the atlas to start from. A scanned object opens in its
    ///   own colours; the chameleon starts blank.
    init(scene: HideScene, geometry: CharacterGeometry, scale: Float, initialPixels: [UInt8]? = nil) throws {
        self.scene = scene
        pose = geometry.pose
        characterScale = scale
        canvas = PaintCanvas(geometry: geometry)
        if let initialPixels, initialPixels.count == canvas.pixels.count {
            canvas.setPixels(initialPixels)
        }
        characterTexture = try LiveTexture(width: geometry.atlasWidth, height: geometry.atlasHeight)
        arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)

        arView.environment.background = .color(UIColor(white: 0.07, alpha: 1))
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows]

        camera.camera.fieldOfViewInDegrees = Self.verticalFieldOfView
        camera.camera.fieldOfViewOrientation = .vertical
        camera.camera.near = 0.01
        camera.camera.far = 20
        root.addChild(camera)

        light.light.intensity = 1600
        light.look(at: .zero, from: [0.6, 1.8, 1.2], relativeTo: nil)
        root.addChild(light)

        sceneFrame.transform = Transform(matrix: scene.anchorToWorld)
        root.addChild(sceneFrame)
        sceneFrame.addChild(environmentEntity)
        sceneFrame.addChild(characterEntity)
        arView.scene.addAnchor(root)

        try buildEnvironment()
        try buildCharacterMesh(geometry)
        uploadCharacter(full: true)
        resetCamera()

        // Someone who has told the iPad they only draw with the Pencil starts in Pencil mode.
        if UIPencilInteraction.prefersPencilOnlyDrawing {
            pencilDetected = true
            fingerPaints = false
        }
        input.install(on: arView, controller: self)
    }

    // MARK: - Building

    private func buildEnvironment() throws {
        let environment = scene.environment
        guard environment.triangleCount > 0 else { return }
        let texture = try LiveTexture(width: environment.atlas.width, height: environment.atlas.height)
        texture.upload(environment.pixels, dirty: nil)
        environmentTexture = texture
        let mesh = try SceneAssets.mesh(environment.renderBuffers(), name: "environment")
        environmentEntity.model = ModelComponent(mesh: mesh, materials: [SceneAssets.environment(texture.resource)])
    }

    private func buildCharacterMesh(_ geometry: CharacterGeometry) throws {
        let mesh = try SceneAssets.mesh(geometry.render, name: "character")
        characterEntity.model = ModelComponent(mesh: mesh, materials: [])
        applyCharacterMaterial()
        applyCharacterTransform()
    }

    private func applyCharacterMaterial() {
        let texture = characterTexture.resource
        if shapeShading {
            characterEntity.model?.materials = [SceneAssets.shaded(texture)]
        } else {
            characterEntity.model?.materials = [SceneAssets.studioPaint(texture)]
        }
    }

    private func applyCharacterTransform() {
        characterEntity.transform = Transform(scale: SIMD3(repeating: characterScale),
                                              rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                              translation: [0, SurfaceFrame.surfaceOffset, 0])
    }

    /// Swaps pose. The atlas layout changes with the mesh, so the paint resets.
    /// Re-poses the chameleon. The paint goes with it, part by part (PoseTransfer), so a
    /// finished paint job survives; undo history starts afresh.
    func changePose(to newPose: CharacterPose) {
        guard newPose != pose, busyMessage == nil else { return }
        busyMessage = "Posing…"
        busyProgress = 0
        let old = canvas.geometry
        let oldPixels = canvas.pixels
        Task {
            let (geometry, pixels) = await Task.detached(priority: .userInitiated) { () -> (CharacterGeometry, [UInt8]?) in
                let geometry = CharacterGeometry.build(from: CharacterShape.build(newPose))
                return (geometry, PoseTransfer(from: old, pixels: oldPixels, to: geometry)?.paintedAtlas())
            }.value
            do {
                let texture = try LiveTexture(width: geometry.atlasWidth, height: geometry.atlasHeight)
                canvas = PaintCanvas(geometry: geometry)
                if let pixels { canvas.setPixels(pixels) }
                characterTexture = texture
                pose = newPose
                try buildCharacterMesh(geometry)
                uploadCharacter(full: true)
                refreshUndoState()
                resetCamera()
            } catch {
                print("Pose change failed: \(error)")
            }
            busyMessage = nil
        }
    }

    // MARK: - Camera

    private var anchorToWorld: simd_float4x4 { scene.anchorToWorld }

    private var characterToWorld: simd_float4x4 {
        anchorToWorld * simd_float4x4(translation: [0, SurfaceFrame.surfaceOffset, 0])
            * simd_float4x4(uniformScale: characterScale)
    }

    func resetCamera() {
        invalidateStrokeCaches()
        let geometry = canvas.geometry
        let localCenter = (geometry.boundsMin + geometry.boundsMax) * 0.5
        orbitTarget = characterToWorld.transformPoint(localCenter)
        // Look from where the hider was: in front of the wall, or from the viewer side of the floor.
        let facing = scene.surface == .wall ? anchorToWorld.yAxis : anchorToWorld.zAxis
        azimuth = atan2(facing.x, facing.z)
        elevation = scene.surface == .wall ? 0.15 : 0.4
        let size = simd_length(geometry.boundsMax - geometry.boundsMin) * characterScale
        distance = max(0.35, size * 2.4)
        updateCamera()
    }

    func orbit(dx: Float, dy: Float) {
        invalidateStrokeCaches()
        azimuth -= dx * 0.008
        elevation = min(max(elevation + dy * 0.006, -0.6), 1.45)
        updateCamera()
    }

    func zoom(by factor: Float) {
        invalidateStrokeCaches()
        distance = min(max(distance / factor, 0.12), 3.5)
        updateCamera()
    }

    func pan(dx: Float, dy: Float) {
        invalidateStrokeCaches()
        let (right, up, _) = cameraBasis()
        let k = distance * 0.0016
        orbitTarget += -right * dx * k + up * dy * k
        updateCamera()
    }

    private func cameraBasis() -> (right: Vec3, up: Vec3, forward: Vec3) {
        let forward = simd_normalize(orbitTarget - cameraPosition)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        return (right, up, forward)
    }

    private func updateCamera() {
        cameraPosition = orbitTarget + distance * Vec3(cos(elevation) * sin(azimuth),
                                                       sin(elevation),
                                                       cos(elevation) * cos(azimuth))
        let (right, up, forward) = cameraBasis()
        camera.transform = Transform(matrix: simd_float4x4(xAxis: right, yAxis: up, zAxis: -forward,
                                                           origin: cameraPosition))
    }

    /// World-space ray through a point in the view (points, top-left origin).
    func worldRay(through point: CGPoint) -> (origin: Vec3, direction: Vec3)? {
        let size = arView.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let (right, up, forward) = cameraBasis()
        let tanHalf = tan(Self.verticalFieldOfView * .pi / 360)
        let aspect = Float(size.width / size.height)
        let ndcX = Float(point.x / size.width) * 2 - 1
        let ndcY = 1 - Float(point.y / size.height) * 2
        let direction = simd_normalize(forward + right * (ndcX * tanHalf * aspect) + up * (ndcY * tanHalf))
        return (cameraPosition, direction)
    }

    // MARK: - Painting

    /// A finger landing here paints if it's on the chameleon (or picking a colour, which
    /// works anywhere); anywhere else it turns the view instead. A few probes round the
    /// point give the silhouette's edge some slack, so a stroke can start just off it.
    func fingerStartsStroke(at point: CGPoint) -> Bool {
        if tool == .eyedropper { return true }
        let worldToCharacter = characterToWorld.inverse
        var probes = [point]
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3
            probes.append(CGPoint(x: point.x + cos(angle) * 14, y: point.y + sin(angle) * 14))
        }
        for probe in probes {
            guard let ray = worldRay(through: probe) else { continue }
            let origin = worldToCharacter.transformPoint(ray.origin)
            let direction = simd_normalize(worldToCharacter.transformDirection(ray.direction))
            if canvas.geometry.bvh.intersect(origin: origin, direction: direction) != nil { return true }
        }
        return false
    }

    func notePencil() {
        if !pencilDetected { pencilDetected = true }
        if fingerPaints { fingerPaints = false }
    }

    /// The finger that started this stroke was the first of a two-finger gesture.
    func abortStroke() {
        canvas.cancelStroke()
        lastDabPoint = nil
        uploadCharacter()
        refreshUndoState()
    }

    func beginStroke(at point: CGPoint, pressure: Float) {
        guard busyMessage == nil else { return }
        if tool == .eyedropper {
            pickColor(at: point)
            return
        }
        canvas.beginStroke()
        lastDabPoint = nil
        camoStamp &+= 1
        if camoStamp == 0 { camoStamp = 1; camoStamps = [] }
        paint(at: point, pressure: pressure)
    }

    private func invalidateStrokeCaches() {
        visibilityIsStale = true
        camoStamp &+= 1
        if camoStamp == 0 { camoStamp = 1; camoStamps = [] }
    }

    /// What the painter can see of the character from here — rebuilt only when the view moves.
    private func visibility(eyeInCharacterSpace eye: Vec3) -> VisibilityMap {
        if let strokeVisibility, !visibilityIsStale, simd_distance(strokeVisibility.eye, eye) < 0.002 {
            return strokeVisibility
        }
        let map = VisibilityMap.build(geometry: canvas.geometry, eye: eye)
        strokeVisibility = map
        visibilityIsStale = false
        return map
    }

    func continueStroke(at points: [(CGPoint, Float)]) {
        guard busyMessage == nil, tool != .eyedropper else { return }
        for (point, pressure) in points {
            paint(at: point, pressure: pressure, upload: false)
        }
        uploadCharacter()
    }

    func endStroke() {
        guard tool != .eyedropper else { return }
        canvas.endStroke()
        lastDabPoint = nil
        uploadCharacter()
        refreshUndoState()
    }

    private func paint(at point: CGPoint, pressure: Float, upload: Bool = true) {
        guard let ray = worldRay(through: point) else { return }
        let worldToCharacter = characterToWorld.inverse
        let origin = worldToCharacter.transformPoint(ray.origin)
        let direction = simd_normalize(worldToCharacter.transformDirection(ray.direction))

        guard let hit = canvas.geometry.bvh.intersect(origin: origin, direction: direction) else {
            lastDabPoint = nil
            return
        }
        let center = origin + direction * hit.t
        let eye = origin
        let clampedPressure = min(max(pressure, 0), 1)
        let radius = brushSizeCentimeters / 100 * (0.55 + 0.45 * clampedPressure) / characterScale
        let strength = opacity * (0.35 + 0.65 * clampedPressure)

        let provider = colorProvider(eyeInCharacterSpace: eye)
        let fade = tool != .camo
        let visible = visibility(eyeInCharacterSpace: eye)
        if let last = lastDabPoint, simd_distance(last, center) < radius * 8 {
            let spacing = max(radius * 0.3, 0.0005)
            let steps = max(1, Int(ceil(simd_distance(last, center) / spacing)))
            for step in 1...steps {
                let p = last + (center - last) * (Float(step) / Float(steps))
                canvas.dab(center: p, radius: radius, eye: eye, opacity: strength, hardness: hardness,
                           fadeAtGrazingAngles: fade, visibility: visible, color: provider)
            }
        } else {
            canvas.dab(center: center, radius: radius, eye: eye, opacity: strength, hardness: hardness,
                       fadeAtGrazingAngles: fade, visibility: visible, color: provider)
        }
        lastDabPoint = center
        if upload { uploadCharacter() }
    }

    private func colorProvider(eyeInCharacterSpace eye: Vec3) -> (Int, Vec3) -> Color3? {
        switch tool {
        case .brush, .eyedropper:
            let flat = color
            return { _, _ in flat }
        case .camo:
            let environment = scene.environment
            let scale = characterScale
            let offset = Vec3(0, SurfaceFrame.surfaceOffset, 0)
            let eyeAnchor = eye * scale + offset
            // Looking up what's behind a texel means a ray cast into the scan; with a big
            // brush the same texels are covered by dab after dab, so results are cached
            // for as long as the viewpoint holds still.
            let count = canvas.geometry.atlasWidth * canvas.geometry.atlasHeight
            if camoColors.count != count {
                camoColors = [Color3](repeating: .zero, count: count)
                camoStamps = [UInt32](repeating: 0, count: count)
            }
            let stamp = camoStamp
            return { [self] texel, position in
                if camoStamps[texel] == stamp { return camoColors[texel] }
                guard let color = Camouflage.backgroundColor(behind: position * scale + offset,
                                                             from: eyeAnchor, environment: environment)
                else { return nil }
                camoColors[texel] = color
                camoStamps[texel] = stamp
                return color
            }
        }
    }

    /// Commits any stroke still in progress (e.g. leaving the studio mid-stroke).
    func finishActiveStroke() {
        canvas.endStroke()
        lastDabPoint = nil
        uploadCharacter()
        refreshUndoState()
    }

    // MARK: - Eyedropper

    func toggleEyedropper() {
        if tool == .eyedropper {
            tool = toolBeforeEyedropper ?? .brush
            toolBeforeEyedropper = nil
        } else {
            toolBeforeEyedropper = tool
            tool = .eyedropper
        }
    }

    private func pickColor(at point: CGPoint) {
        guard let ray = worldRay(through: point) else { return }
        let worldToAnchor = anchorToWorld.inverse
        let anchorOrigin = worldToAnchor.transformPoint(ray.origin)
        let anchorDirection = simd_normalize(worldToAnchor.transformDirection(ray.direction))

        let worldToCharacter = characterToWorld.inverse
        let characterOrigin = worldToCharacter.transformPoint(ray.origin)
        let characterDirection = simd_normalize(worldToCharacter.transformDirection(ray.direction))

        let characterHit = canvas.geometry.bvh.intersect(origin: characterOrigin, direction: characterDirection)
        let environmentHit = showEnvironment ? scene.environment.trace(origin: anchorOrigin, direction: anchorDirection) : nil

        var picked: Color3?
        if let characterHit, (environmentHit == nil || characterHit.t * characterScale < environmentHit!.hit.t) {
            picked = canvas.color(near: characterOrigin + characterDirection * characterHit.t)
        } else if let environmentHit {
            picked = environmentHit.color
        }

        if let picked {
            color = picked
            remember(picked)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        tool = toolBeforeEyedropper ?? .brush
        toolBeforeEyedropper = nil
    }

    func remember(_ newColor: Color3) {
        recentColors.removeAll { simd_distance($0, newColor) < 0.02 }
        recentColors.insert(newColor, at: 0)
        if recentColors.count > 10 { recentColors.removeLast() }
    }

    // MARK: - Whole-body operations

    func autoCamouflage() {
        runWholeBody("Camouflaging…") { canvas, scene, scale in
            let colours = Camouflage.paintAll(geometry: canvas.geometry, scale: scale,
                                              viewpoints: Camouflage.seekerViewpoints(scanned: scene.viewpoints),
                                              environment: scene.environment)
            return { texel, _, _ in colours[texel] }
        }
    }

    /// Paints the entire character in the selected color.
    func fillWithCurrentColor() {
        let flat = color
        runWholeBody("Filling…") { _, _, _ in { _, _, _ in flat } }
    }

    func resetPaint() {
        runWholeBody("Clearing…") { _, _, _ in
            let base = PaintCanvas.baseColor
            return { _, _, _ in base }
        }
    }

    private func runWholeBody(_ message: String,
                              makeColor: @escaping @Sendable (PaintCanvas, HideScene, Float) -> @Sendable (Int, Vec3, Vec3) -> Color3?) {
        guard busyMessage == nil else { return }
        busyMessage = message
        busyProgress = 0
        let canvas = self.canvas
        let scene = self.scene
        let scale = characterScale
        Task {
            await Task.detached(priority: .userInitiated) { [weak self] in
                let color = makeColor(canvas, scene, scale)
                canvas.applyToAllTexels(color) { progress in
                    Task { @MainActor in self?.busyProgress = progress }
                }
            }.value
            uploadCharacter(full: true)
            refreshUndoState()
            busyMessage = nil
        }
    }

    // MARK: - Undo

    func undo() {
        canvas.undo()
        uploadCharacter()
        refreshUndoState()
    }

    func redo() {
        canvas.redo()
        uploadCharacter()
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = canvas.canUndo
        canRedo = canvas.canRedo
    }

    // MARK: - Upload

    private func uploadCharacter(full: Bool = false) {
        let dirty = canvas.takeDirtyRect()
        guard full || dirty != nil else { return }
        characterTexture.upload(canvas.pixels, dirty: full ? nil : dirty)
    }

    // MARK: - Debug hooks (used by launch arguments for automated checks)

    #if DEBUG
    func debugStroke(from start: CGPoint, to end: CGPoint, samples: Int = 40) {
        beginStroke(at: start, pressure: 1)
        var points: [(CGPoint, Float)] = []
        for i in 1...samples {
            let t = CGFloat(i) / CGFloat(samples)
            points.append((CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), 1))
        }
        continueStroke(at: points)
        endStroke()
    }

    func debugSetCamera(azimuthDegrees: Float, elevationDegrees: Float, distance newDistance: Float) {
        azimuth = azimuthDegrees * .pi / 180
        elevation = elevationDegrees * .pi / 180
        distance = newDistance
        updateCamera()
    }

    var debugAzimuthDegrees: Float { azimuth * 180 / .pi }

    #endif
}
