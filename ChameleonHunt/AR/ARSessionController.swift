//
//  ARSessionController.swift
//  Owns the live AR view: LiDAR session, floor/wall placement with a ghost
//  preview, scanning, finding the hiding spot again after the studio, and the
//  seeker's taps. Drawing the painted character is delegated to CharacterPresenter.
//
//  Why relocalization matters: the AR view has to leave the screen while the
//  hider paints (only one RealityKit view can render at a time), and ARKit tracking
//  pauses with it. ARKit then resumes "from the last known state" — if the iPad was
//  moved in the meantime, world coordinates are off. So the scan saves an
//  ARWorldMap, and returning to AR relocalizes against it before the character is
//  shown.
//

import ARKit
import RealityKit
import SwiftUI
import Combine

/// Everything captured by a scan, ready to be processed off the main thread.
struct ScanCapture: Sendable {
    let keyframes: [Keyframe]
    let worldV0: [Vec3]
    let worldV1: [Vec3]
    let worldV2: [Vec3]
    let anchorToWorld: simd_float4x4
    let surface: SurfaceKind
}

@MainActor
final class ARSessionController: NSObject, ObservableObject, ARSessionDelegate, UIGestureRecognizerDelegate {

    enum Mode: Equatable {
        case idle
        case placing
        case scanning
        case showing
        case hunting
    }

    /// Progress of the shape search that puts the character back where it was hidden.
    enum SearchState: Equatable {
        case idle
        /// Nothing recognizable in view yet — the seeker needs to point at the area.
        case looking
        /// A match was found once and is being confirmed.
        case confirming
        case found(moved: Float, turned: Float)
    }

    /// Where the painted character stands, as far as the live AR view is concerned.
    enum CharacterStatus: Equatable {
        /// No painted character yet.
        case none
        /// Waiting for ARKit to recognize the scanned hiding spot.
        case locating
        /// Anchored at the hiding spot and rendering.
        case visible
        /// The hider is choosing a new spot for the painted character.
        case replacing
    }

    struct Probe: Equatable {
        var surface: SurfaceKind?
        var isPlaceable: Bool
        /// The spot under the reticle looks glossy, glass or mirror-like — where
        /// camouflage works worst, because what you see there changes as you move.
        var looksShiny = false
    }

    static let anchorName = "hide-spot"

    /// How hard the app is currently trying to find the hiding spot again.
    private enum LocatingStage {
        /// Carry on with the session that was already running — tracking often survives
        /// the trip through the studio, and then the spot is simply still there.
        case resume
        /// Reload the map saved after the scan and let ARKit re-recognize the room.
        case worldMap
    }

    // MARK: Published

    @Published private(set) var probe: Probe?
    @Published private(set) var trackingHint: String?
    @Published private(set) var keyframeCount = 0
    @Published private(set) var coverage = [Bool](repeating: false, count: KeyframeCollector.bucketCount)
    @Published private(set) var meshTriangleCount = 0
    @Published private(set) var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published private(set) var characterStatus: CharacterStatus = .none
    @Published private(set) var locatingSince: Date?
    /// Screen-space direction (radians, 0 = right, clockwise) toward the character when it's off screen.
    @Published private(set) var offscreenDirection: Double?
    /// After a hint: the one it points to is on screen (so there's no arrow to follow).
    @Published private(set) var hintTargetInView = false
    /// A photo from the scan, shown while relocalizing so the hider knows where to point.
    @Published private(set) var spotPhoto: UIImage?
    /// Why the character isn't showing yet, or how far it has drifted.
    @Published private(set) var spotIssue: String?
    /// Result of snapping a hand placement back onto the scan.
    @Published private(set) var snapMessage: String?
    /// Live readout for the diagnostics panel (only updated while it's open).
    @Published private(set) var diagnosticLines: [String] = []
    @Published var showDiagnostics = false
    /// Keep the paint as bright as the room looks right now.
    @Published var lightingMatchEnabled = true {
        didSet {
            if !lightingMatchEnabled {
                lighting.reset()
                presenter.applyLighting([1, 1, 1])
            }
        }
    }
    /// Pose shown by the ghost; auto-switches when the surface type changes.
    @Published var pose: CharacterPose = .standing { didSet { refreshGhost() } }
    /// Turns the character on the spot while placing it, in radians about the surface normal.
    @Published var placementYaw: Float = 0 { didSet { refreshGhost() } }
    @Published var characterScale: Float = 1 {
        didSet {
            refreshGhost()
            presenter.scale = characterScale
        }
    }

    var onSeekerHit: (() -> Void)?
    var onSeekerMiss: (() -> Void)?
    /// "Lots of them" game: the seeker tapped one they hadn't found yet.
    var onSeekerFoundOne: ((ChameleonActor) -> Void)?
    /// Points the edge arrow at the nearest chameleon still hidden (the clue in the
    /// "lots of them" game).
    var pointsToNearestHidden = false

    static var isLiDARAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-debugNoLiDAR") { return false }
        #endif
        return ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    /// Any AR at all. Without LiDAR the game still runs, cut down: chameleons go on the
    /// flat surfaces ARKit finds, and only people (or a shared room map, in a squad) hide
    /// them.
    static var isARAvailable: Bool { ARWorldTrackingConfiguration.isSupported }

    var hasWorldMap: Bool { worldMap != nil }
    /// Whether the spot being scanned is on a wall — the scan instructions differ.
    var hideSurfaceIsWall: Bool { hideSurface == .wall }

    // MARK: Internals

    let arView: ARView
    let presenter: CharacterPresenter
    private(set) var mode: Mode = .idle
    private var lastFloorPose: CharacterPose = .standing

    private let worldRoot = AnchorEntity(world: .zero)
    private let ghost = ModelEntity()
    private var ghostMeshes: [CharacterPose: MeshResource] = [:]
    private var ghostFrame: simd_float4x4?
    /// With nothing to stand it on yet, the preview floats a little way ahead, faded, so
    /// it's clear what's being aimed and that it can't go there. (Without LiDAR, until
    /// ARKit has found a flat surface, there used to be nothing on screen at all.)
    private var floatingFrame: simd_float4x4?
    /// Holds the placing preview still against sensor noise and a shaky hand.
    private var aim = AimStabilizer()
    /// What the ghost is currently showing, so it's only rebuilt when that changes.
    private var ghostKey: (pose: CharacterPose, valid: Bool)?
    private static let ghostMaterials = (valid: SceneAssets.ghost(valid: true), invalid: SceneAssets.ghost(valid: false))

    /// The "lots of them" game: every tap of the shutter drops another chameleon.
    @Published private(set) var scatterMode = false
    let scatter: ScatterStage

    /// The scanning ring, and how full it is (0…1).
    private(set) lazy var scanRing = ScanRing(parent: worldRoot)
    @Published private(set) var ringProgress: Float = 0
    /// A plain-words nudge while scanning ("Come a bit closer"), or nil when all is well.
    @Published private(set) var scanNudge: String?
    /// True once the ring has stopped filling for a while — a spot on the ceiling or on
    /// top of a wardrobe can't be walked all the way round, so the scan offers to make
    /// do with what it has rather than leave the hider stuck.
    @Published private(set) var scanStalled = false
    private var scanStartedAt: TimeInterval = 0
    private var lastRingGrowthAt: TimeInterval = 0
    private let tickHaptic = UIImpactFeedbackGenerator(style: .light)

    private var hideAnchor: ARAnchor?
    private var hideSurface: SurfaceKind = .floor

    private var worldMap: ARWorldMap?
    private var relocalizationPending = false
    /// Scan points in hide-anchor space, kept ready for the spot search.
    private var scanFingerprint: [Vec3] = []
    private var searchTask: Task<Void, Never>?
    private var lastSearchAt = Date.distantPast
    /// The previous good match, so a spot has to be found twice before it's committed.
    private var searchCandidate: (transform: simd_float4x4, at: Date)?
    @Published private(set) var searchState: SearchState = .idle
    private var sawRelocalizingState = false
    private var stage: LocatingStage = .resume
    private var stageStarted = Date()
    /// False once the character has been re-placed by hand: the scanned surroundings no
    /// longer describe where it stands, so they can't be used to verify it.
    private var scanMatchesSpot = true
    private var lastCameraPosition: Vec3?
    // Keeping the chameleons hidden and changing colour.
    private var lastCoverageTime: TimeInterval = 0
    private var lastLivingTime: TimeInterval = 0
    private var livingFrameInFlight = false
    private var previousCameraTransform: simd_float4x4?
    private var previousCameraTime: TimeInterval = 0
    private(set) var cameraMotion: Float = 0
    /// How strongly chameleons change colour during a hunt (0 = off); set per round.
    var huntLivingStrength: Float = 0.6

    /// The AR view as it looks right now — the room and the chameleons, none of the
    /// buttons — for sharing. RealityKit hands the picture back on its own terms, so the
    /// closure given to it is sendable and hops to the main actor itself (a main-actor
    /// closure run anywhere else stops the app under Swift 6).
    func snapshot(_ done: @escaping @MainActor @Sendable (UIImage) -> Void) {
        arView.snapshot(saveToHDR: false) { @Sendable image in
            guard let image else { return }
            let box = UncheckedSendable(value: image)
            Task { @MainActor in done(box.value) }
        }
    }

    /// The hunt's difficulty: the seeker's choice in Swarm, the host's in Squad.
    private(set) var huntDifficulty: HuntDifficulty = .easy

    /// A hunt (Swarm's or Squad's) is about to start at this difficulty: how closely the
    /// chameleons match the room from now on, how soon they fade with distance, and how
    /// near a tap must land.
    func applyHuntDifficulty(_ difficulty: HuntDifficulty) {
        huntDifficulty = difficulty
        huntLivingStrength = difficulty.camouflage(base: swarmHuntStrength)
        for actor in scatter.actors where !actor.livingIsPermanent {
            actor.livingStrength = huntLivingStrength
        }
    }

    /// Debug: use the display curve measured on this device (as normal) or only the one
    /// fitted to the playtest screenshots, to compare the two.
    var measuresColours: Bool {
        get { SceneAssets.usesMeasuredCurve }
        set {
            guard newValue != SceneAssets.usesMeasuredCurve else { return }
            objectWillChange.send()
            SceneAssets.usesMeasuredCurve = newValue
            redrawChameleons()
        }
    }

    private func redrawChameleons() {
        for actor in scatter.actors { actor.redraw() }
        presenter.actor?.redraw()
        scatter.redrawPreview()
    }

    /// The difficulty the hunt in front of the camera plays at.
    private var activeDifficulty: HuntDifficulty { scatterMode ? huntDifficulty : .easy }

    /// Swarm and Squad: how strongly the chameleons keep matching the room during the
    /// hunt — a touch less on a phone, a touch more on a big iPad (ScreenDifficulty).
    var swarmHuntStrength: Float {
        let screen = arView.window?.windowScene?.screen
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let size = screen?.bounds.size ?? arView.bounds.size
        let inches = ScreenDifficulty.diagonalInches(width: Float(size.width), height: Float(size.height),
                                                     isPad: UIDevice.current.userInterfaceIdiom == .pad)
        return ScreenDifficulty.livingStrength(base: GameConfig.scatterLivingStrength, diagonalInches: inches)
    }

    private let collector = KeyframeCollector()
    private let lighting = LightingMatch()
    private var hideScene: HideScene?
    private var lastProbeTime: TimeInterval = 0
    private var lastMeshCountTime: TimeInterval = 0
    private var lastArrowTime: TimeInterval = 0
    private var lastDiagnosticsTime: TimeInterval = 0
    private var lastSurfaceCheck: TimeInterval = 0
    private var sessionStarted = false
    private var configuration: ARWorldTrackingConfiguration?

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        presenter = CharacterPresenter(arView: arView, root: worldRoot)
        scatter = ScatterStage(arView: arView, root: worldRoot)
        super.init()

        arView.session.delegate = self
        // @Sendable: KVO calls this on whichever thread changed the value.
        sessionIDObservation = arView.session.observe(\.identifier, options: [.initial, .new]) { @Sendable [weak self] session, _ in
            let id = session.identifier
            Task { @MainActor in self?.sessionID = id }
        }
        // Grounding shadows, HDR tone mapping and environment lighting would each shift the
        // painted colours away from what was matched, so they stay off. Camera grain,
        // motion blur and depth of field stay *on*: the camera image is noisy, smears when
        // the iPad moves and is soft out of focus, and a chameleon that's none of those
        // things is exactly what makes it look pasted on.
        arView.renderOptions = [.disableGroundingShadows, .disableHDR, .disableAREnvironmentLighting]
        arView.scene.addAnchor(worldRoot)
        ghost.isEnabled = false
        worldRoot.addChild(ghost)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)

        // Drag to turn the character while placing it.
        let rotate = UIPanGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        rotate.maximumNumberOfTouches = 1
        arView.addGestureRecognizer(rotate)

        // Pinch to make it bigger or smaller, twist to turn — the gestures people already
        // use on photos, instead of sliders.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        arView.addGestureRecognizer(pinch)
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist(_:)))
        twist.delegate = self
        arView.addGestureRecognizer(twist)

        collector.onChange = { [weak self] cameraPosition in
            guard let self else { return }
            self.keyframeCount = self.collector.keyframes.count
            self.coverage = self.collector.coverage
            self.fillScanRing(from: cameraPosition)
        }

        Task { await buildGhostMeshes() }
    }

    private func buildGhostMeshes() async {
        let shapes = await Task.detached(priority: .utility) {
            CharacterPose.allCases.map { CharacterShape.build($0) }
        }.value
        for shape in shapes {
            ghostMeshes[shape.pose] = try? SceneAssets.ghostMesh(shape)
        }
        refreshGhost()
    }

    // MARK: - Session

    func startSessionIfNeeded() {
        guard !sessionStarted else { return }
        startNewRound()
    }

    /// Every round starts on a clean AR session.
    ///
    /// Carrying the last round's session over is what broke the paint studio in second
    /// rounds. Between rounds the AR view comes off screen and ARKit pauses; when it
    /// resumes, it tries to relocalize to where it was (or to the world map saved for
    /// the last hunt), and that can succeed halfway through the *next* scan. The world's
    /// coordinates jump, so the camera positions recorded before the jump and the room
    /// mesh after it no longer line up — and the studio shows the chameleon inside a
    /// wall, a missing floor, or an empty grey room. Starting afresh makes round two
    /// exactly like round one.
    func startNewRound(collaborative: Bool = false) {
        guard Self.isARAvailable else { return }
        sessionStarted = true
        let configuration = ARWorldTrackingConfiguration()
        // Squad play: ARKit shares its map of the room and every anchor with the other
        // devices, so a chameleon hidden on one appears in the same spot on all of them.
        configuration.isCollaborationEnabled = collaborative
        configuration.planeDetection = [.horizontal, .vertical]
        if Self.isLiDARAvailable {
            configuration.sceneReconstruction = .mesh
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            // No depth sensor: at least people walking in front hide the chameleons
            // (RealityKit cuts them out from the camera image).
            configuration.frameSemantics.insert(.personSegmentationWithDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        // Temporally smoothed depth flickers less at object edges; used for occlusion.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        configuration.environmentTexturing = .none
        self.configuration = configuration

        // Collision on the reconstructed mesh gives exact hit points and normals
        // for placement, on walls as well as floors.
        arView.environment.sceneUnderstanding.options = [.collision]
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        sessionID = arView.session.identifier
        forgetHuntMap(sessionRestarted: true)
        hideAnchor = nil
        worldMap = nil
        previousCameraTransform = nil
        cameraMotion = 0
    }

    // MARK: - Lots of chameleons

    /// Starts the "lots of them" game: the reticle drops a chameleon with every tap.
    func beginScatter(scale: Float) {
        scatter.clear()
        scatter.prepare()
        scatterMode = true
        characterScale = scale
        placementYaw = Float.random(in: -.pi ... .pi)
        setMode(.placing)
    }

    /// Drops one where the ghost is, in the colour of the spot it lands on.
    @discardableResult
    func dropScatterChameleon() -> Bool {
        let id = UUID()
        guard let placement = ghostFrame, dropScatterChameleon(id: id, owner: .local) != nil else { return false }
        // Fixed to the room the same way a squad chameleon is: on an ARKit anchor. When
        // ARKit corrects its idea of the room (after the device was put down, say), an
        // anchor moves with the correction; something left at plain coordinates doesn't,
        // and ends up a little off the spot it was hidden on.
        let anchor = ARAnchor(name: Self.swarmPrefix + id.uuidString, transform: placement)
        arView.session.add(anchor: anchor)
        swarmAnchors[id] = anchor
        return true
    }

    /// Takes back the last one dropped (Swarm).
    func undoScatterChameleon() {
        if let id = scatter.records.last?.id, let anchor = swarmAnchors.removeValue(forKey: id) {
            arView.session.remove(anchor: anchor)
        }
        scatter.undo()
    }

    private static let swarmPrefix = "swarm:"
    /// Swarm: each chameleon's anchor in the room.
    private var swarmAnchors: [UUID: ARAnchor] = [:]

    /// ARKit moved some anchors (it refined its map): Swarm's chameleons go with theirs.
    fileprivate func swarmAnchorsChanged(_ anchors: [ARAnchor]) {
        guard scatterMode, !squadMode, !swarmAnchors.isEmpty else { return }
        for anchor in anchors {
            guard let name = anchor.name, name.hasPrefix(Self.swarmPrefix),
                  let id = UUID(uuidString: String(name.dropFirst(Self.swarmPrefix.count))),
                  swarmAnchors[id] != nil else { continue }
            scatter.move(id, to: anchor.transform)
        }
    }

    /// Drops one where the ghost is. Returns the pose it was dropped in.
    private func dropScatterChameleon(id: UUID, owner: Player) -> CharacterPose? {
        // Not while the chameleons are hidden for lost tracking: one dropped then would be
        // counted and never seen (which happened, after Back to hiding while the device
        // was still finding its place in the room).
        guard scatterMode, mode == .placing, !trackingGuard.hidden, let placement = ghostFrame,
              probe?.isPlaceable == true, let frame = arView.session.currentFrame else { return nil }
        let dropped = pose
        let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let colour = CameraColorSampler.color(from: frame, at: centre, viewportSize: arView.bounds.size,
                                              orientation: interfaceOrientation, patchRadius: 8)
            ?? Color3(0.55, 0.55, 0.52)
        guard scatter.drop(pose: pose, scale: characterScale, placement: placement, colour: colour,
                           frame: LiveFrameSnapshot(frame), id: id, owner: owner) else { return nil }
        // The next one faces a different way, and on a floor or shelf strikes a different
        // pose, so they don't all look alike.
        placementYaw = Float.random(in: -.pi ... .pi)
        let poses = CharacterPose.poses(for: pose.surface)
        if poses.count > 1, let next = poses.filter({ $0 != pose }).randomElement() { pose = next }
        return dropped
    }

    // MARK: - Squad play

    /// Playing with others, each on their own device.
    @Published private(set) var squadMode = false
    /// The other devices' AR sessions this one has met: ARKit has merged their maps, so
    /// anchors placed on either now land in the same physical spot on both.
    @Published private(set) var metSessions: Set<UUID> = []
    /// ARKit's map updates to send to the others (data, and whether it must arrive).
    var onCollaborationData: ((Data, Bool) -> Void)?
    /// The seeker tapped someone else's chameleon.
    var onSquadClaim: ((UUID) -> Void)?
    /// The seeker tapped nothing (squad).
    var onSquadMiss: (() -> Void)?
    /// Squad, Medium and Hard: this player's taps don't count until then (a miss's cost).
    var squadTapLock: Date?
    var localSessionID: UUID { arView.session.identifier }
    /// The same, published. ARKit issues a new one whenever the session is reset, and the
    /// other devices know this one by it, so squad play announces each new one.
    @Published private(set) var sessionID: UUID?
    private var sessionIDObservation: NSKeyValueObservation?
    private var squadMe: UUID?
    /// Where each squad chameleon's anchor is in this device's world, local or not.
    private var squadAnchors: [UUID: simd_float4x4] = [:]
    private var squadLocalAnchors: [UUID: ARAnchor] = [:]
    private var squadDetails: [UUID: SquadChameleon] = [:]
    private static let squadPrefix = "squad:"

    /// Squad play: whether this device hosts. The host lays down the shared reference point.
    private var squadIsHost = false
    /// The host's reference point in the room, in this device's coordinates — an ARKit
    /// anchor the host drops as syncing starts, which every device receives once its map
    /// has merged with the host's. Chameleons travel relative to it (SquadChameleon.spot),
    /// so a device only has to sync with the host, not with every other player: with four
    /// players that's three syncs instead of six pairs, which is what made syncing a chore.
    @Published private(set) var squadOrigin: simd_float4x4?
    private var squadOriginID: UUID?
    private static let originPrefix = "squad-origin:"
    /// Others' chameleons placed from their spot because the owner's own anchor hasn't
    /// reached this device (its map hasn't merged with theirs); moved onto the anchor,
    /// which is a little more precise close up, when it arrives.
    private var placedFromSpot: Set<UUID> = []
    /// How far each of the others' chameleons was moved, along its "up", to sit on this
    /// device's LiDAR mesh (see settle).
    private var settleOffsets: [UUID: Float] = [:]
    private var lastSettleTime: TimeInterval = 0
    private var squadNames: [UUID: String] = [:]
    private var squadColours: [UUID: UIColor] = [:]
    private var squadPhase: SquadPhase = .lobby
    /// This player gave up the hunt: they see where the rest are.
    private var squadGaveUp = false
    /// How spread out this round's chameleons are (RoomSpread.ease), worked out now and then.
    private var roomEase: Float = 0
    private var lastSpreadTime: TimeInterval = 0
    private var squadShowMine = false
    private var squadSeeking = true
    /// Squad: name tags over the found chameleons, drawn by the hunt's HUD.
    let tags = ChameleonTags()
    private var lastTagTime: TimeInterval = 0
    /// Lost tracking (camera covered, the iPad face down): the chameleons fade out until
    /// it's back and has settled, rather than be seen where ARKit wrongly thinks they are
    /// (TrackingGuard decides when).
    private var trackingFade: Float = 1
    private var trackingGuard = TrackingGuard()
    private var lastFadeTime: TimeInterval = 0
    /// ARKit's map of the room, saved while a hunt's chameleons are where they should be:
    /// what the device matches the camera against to find its place again after it's
    /// been blind long enough to have been moved (refindRoom).
    private var huntMap: ARWorldMap?
    /// Bumped whenever the saved map stops being this round's, so a late answer from
    /// ARKit isn't kept.
    private var huntMapRound = 0
    private var lastHuntMapTime: TimeInterval = 0
    private var trackingGoodSince: TimeInterval?
    /// Finding its place in the room again (the chameleons are hidden meanwhile).
    @Published private(set) var isRefindingRoom = false

    /// The strip of known greys shown for a moment to measure how textures reach the
    /// screen (calibrateColours), and how that's going.
    private var colourPatch: AnchorEntity?
    private var colourCalibrating = false
    private var colourMeasuredThisRound = false
    private var colourAttempts = 0
    private var lastColourTry: TimeInterval = 0
    private var colourNote = "fitted curve (not measured yet)"

    /// Starts (or restarts) a shared AR session for squad play.
    func startSquadSession(me: UUID, isHost: Bool) {
        reset()
        squadMode = true
        squadMe = me
        squadIsHost = isHost
        metSessions = []
        squadAnchors = [:]
        squadLocalAnchors = [:]
        squadDetails = [:]
        squadOrigin = nil
        squadOriginID = nil
        placedFromSpot = []
        settleOffsets = [:]
        squadGaveUp = false
        squadTapLock = nil
        huntDifficulty = .easy
        huntLivingStrength = swarmHuntStrength
        tags.clear()
        startNewRound(collaborative: true)
        scatter.prepare()
        scatterMode = true
        characterScale = 0.8
        setMode(.showing)
    }

    func endSquadSession() {
        squadMode = false
        squadMe = nil
        squadIsHost = false
        squadOrigin = nil
        squadOriginID = nil
        placedFromSpot = []
        settleOffsets = [:]
        tags.clear()
        onCollaborationData = nil
        reset()
        clearRoomMap()
        if Self.isARAvailable, sessionStarted { startNewRound() }
    }

    /// ARKit map data from another device.
    func receiveCollaboration(_ data: Data) {
        guard squadMode,
              let collaboration = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARSession.CollaborationData.self,
                                                                         from: data) else { return }
        arView.session.update(with: collaboration)
    }

    /// Hiding phase: those who hide get the chameleon to aim with; the rest just look.
    func beginSquadHiding(canHide: Bool) {
        placementYaw = Float.random(in: -.pi ... .pi)
        setMode(canHide ? .placing : .showing)
    }

    /// Drops one of this player's chameleons and shares its spot with everyone.
    func dropSquadChameleon() -> SquadChameleon? {
        guard squadMode, let me = squadMe, let placement = ghostFrame else { return nil }
        let id = UUID()
        let scale = characterScale
        guard let dropped = dropScatterChameleon(id: id, owner: Player(id: me, name: "")) else { return nil }
        let anchor = ARAnchor(name: Self.squadPrefix + id.uuidString, transform: placement)
        arView.session.add(anchor: anchor)
        squadLocalAnchors[id] = anchor
        squadAnchors[id] = placement
        let spot = squadOrigin.map { Self.flatten($0.inverse * placement) }
        return SquadChameleon(id: id, owner: me, pose: dropped.rawValue, scale: scale, spot: spot)
    }

    /// Takes back the last one this player dropped.
    func undoSquadChameleon() -> UUID? {
        guard let id = scatter.records.last(where: { $0.hiddenBy.id == squadMe })?.id else { return nil }
        scatter.remove(id)
        if let anchor = squadLocalAnchors.removeValue(forKey: id) { arView.session.remove(anchor: anchor) }
        squadAnchors[id] = nil
        return id
    }

    /// Brings this device's chameleons in line with the game: creates the ones other
    /// players hid (once their anchor has arrived), removes any that are gone, marks the
    /// found ones, and shows or hides each for this phase.
    /// `colours`: each player's colour. A found one takes its finder's; at the end the
    /// unfound ones light up in whoever hid them — every chameleon shows who got its point.
    /// `names`: each player's name, for the tags. `gaveUp`: this player has given up the
    /// hunt, so the ones still hidden show, in their hider's colour. `showMine`: this
    /// player wants to see their own during the hunt (off by default: seeing them only
    /// confused people). `seeking`: this player is hunting — someone who isn't (the hider
    /// in hider vs all, or after giving up) always sees their own.
    func syncSquad(chameleons: [SquadChameleon], phase: SquadPhase, colours: [UUID: UIColor] = [:],
                   names: [UUID: String] = [:], gaveUp: Bool = false, showMine: Bool = false, seeking: Bool = true) {
        guard squadMode, let me = squadMe else { return }
        squadDetails = Dictionary(uniqueKeysWithValues: chameleons.map { ($0.id, $0) })
        squadColours = colours
        squadNames = names
        squadPhase = phase
        squadGaveUp = gaveUp
        squadShowMine = showMine
        squadSeeking = seeking
        let wanted = Set(chameleons.map(\.id))
        for record in scatter.records where !wanted.contains(record.id) && record.hiddenBy.id != me {
            scatter.remove(record.id)
            placedFromSpot.remove(record.id)
            settleOffsets[record.id] = nil
        }
        for chameleon in chameleons where chameleon.owner != me {
            if scatter.actor(chameleon.id) == nil, let placement = placement(for: chameleon),
               let pose = CharacterPose(rawValue: chameleon.pose) {
                scatter.addRemote(id: chameleon.id, owner: chameleon.owner, pose: pose, scale: chameleon.scale,
                                  placement: settled(placement, id: chameleon.id), livingStrength: huntLivingStrength)
            }
        }
        let hunting = phase == .hunting || phase == .results
        for chameleon in chameleons {
            guard let actor = scatter.actor(chameleon.id) else { continue }
            if chameleon.foundBy == nil, actor.isFound, phase != .hunting {
                // Tapped here, but the host never counted it (it arrived after time was
                // up): it wasn't found, whatever this screen said at the time.
                actor.isFound = false
                actor.setMarked(false)
            }
            if let finder = chameleon.foundBy {
                // Everyone sees every find, in the finder's colour — your own included.
                scatter.markFound(chameleon.id, colour: colours[finder] ?? .systemPink)
            } else if chameleon.owner == me {
                if phase == .hunting {
                    // Yours, while the others hunt: not shown unless you've asked to see
                    // them, or you're only watching. When shown, see-through white, and
                    // over whatever's in front of them, so there's no mistaking them.
                    let show = showMine || !seeking
                    actor.suppressed = !show
                    actor.shownAsMine = show
                    actor.occlusionEnabled = false
                } else {
                    // While hiding, real things hide them, so you can judge the spot.
                    actor.suppressed = false
                    actor.shownAsMine = false
                    actor.occlusionEnabled = true
                }
            } else {
                actor.suppressed = !hunting
            }
        }
        if phase == .results {
            scatter.revealUnfound { actor in actor.owner.flatMap { colours[$0] } ?? .white }
        } else if phase == .hunting, gaveUp {
            scatter.revealUnfound(excludingOwner: me) { actor in actor.owner.flatMap { colours[$0] } ?? .white }
        }
    }

    /// Where someone else's chameleon is in this device's world: its owner's anchor if
    /// that has arrived, otherwise its spot from the host's reference point.
    private func placement(for chameleon: SquadChameleon) -> simd_float4x4? {
        if let anchored = squadAnchors[chameleon.id] {
            placedFromSpot.remove(chameleon.id)
            return anchored
        }
        guard let origin = squadOrigin, let spot = chameleon.spot.flatMap(Self.matrix) else { return nil }
        placedFromSpot.insert(chameleon.id)
        return origin * spot
    }

    /// The reference point moved (ARKit refined its map): the chameleons placed from it
    /// move with it.
    private func replaceFromSpots() {
        guard let origin = squadOrigin else { return }
        for id in placedFromSpot {
            guard let spot = squadDetails[id]?.spot.flatMap(Self.matrix) else { continue }
            scatter.move(id, to: settled(origin * spot, id: id))
        }
    }

    /// Someone else's chameleon, lifted or lowered onto this device's LiDAR mesh if it
    /// was placed a little off it. A phone without LiDAR places on a surface ARKit
    /// estimated, often a centimetre or three from the real one; on an iPad that left it
    /// sunk into the table, where the table hid it — in testing, one simply vanished.
    private func settled(_ transform: simd_float4x4, id: UUID) -> simd_float4x4 {
        guard let offset = settleOffsets[id] else { return transform }
        var moved = transform
        moved.columns.3 = SIMD4<Float>(transform.translation + simd_normalize(transform.yAxis) * offset, 1)
        return moved
    }

    /// Looks for the surface under each of the others' chameleons not yet settled, about
    /// once a second (the mesh fills in as the room is looked at). Only surfaces facing
    /// up, near where it was put — never the underside of a sofa it's hidden beneath.
    private func settleOthers(_ time: TimeInterval) {
        guard Self.isLiDARAvailable, squadMode, time - lastSettleTime > 1 else { return }
        lastSettleTime = time
        for actor in scatter.actors where actor.owner != squadMe && settleOffsets[actor.id] == nil && !actor.isFound {
            let placed = actor.placement
            let origin = placed.translation
            let up = simd_normalize(placed.yAxis)
            let hits = arView.scene.raycast(origin: origin + up * 0.12, direction: -up, length: 0.24,
                                            query: .all, mask: .sceneUnderstanding, relativeTo: nil)
            let facingUp = hits.filter { simd_dot(simd_normalize($0.normal), up) > 0.7 }
            guard let nearest = facingUp.min(by: { abs(simd_dot($0.position - origin, up)) < abs(simd_dot($1.position - origin, up)) })
            else { continue }
            let offset = simd_dot(nearest.position - origin, up)
            settleOffsets[actor.id] = abs(offset) > 0.008 ? offset : 0
            if abs(offset) > 0.008 {
                var moved = placed
                moved.columns.3 = SIMD4<Float>(origin + up * offset, 1)
                scatter.move(actor.id, to: moved)
            }
        }
    }

    /// The host drops the shared reference point once tracking is steady.
    private func maintainSquadOrigin(_ frame: ARFrame) {
        guard squadMode, squadIsHost, squadOriginID == nil, case .normal = frame.camera.trackingState else { return }
        let anchor = ARAnchor(name: Self.originPrefix + UUID().uuidString,
                              transform: simd_float4x4(translation: frame.camera.transform.translation))
        arView.session.add(anchor: anchor)
        squadOriginID = anchor.identifier
        squadOrigin = anchor.transform
    }

    /// Name tags over the chameleons that are lit up — who found whose, or whose nobody
    /// found — and over your own if you've chosen to see them, about twelve times a second.
    private func updateTags(_ frame: ARFrame) {
        guard squadMode, squadPhase == .hunting || squadPhase == .results else {
            tags.clear()
            return
        }
        guard frame.timestamp - lastTagTime > 1.0 / 12 else { return }
        lastTagTime = frame.timestamp
        let camera = frame.camera.transform
        let eye = camera.translation
        let forward = -simd_normalize(camera.zAxis)
        var list: [ChameleonTags.Tag] = []
        if trackingFade > 0.5 {
            for actor in scatter.actors where (actor.isMarked || actor.shownAsMine) && !actor.suppressed {
                guard let details = squadDetails[actor.id] else { continue }
                let g = actor.geometry
                let top = actor.characterToWorld.transformPoint(
                    Vec3((g.boundsMin.x + g.boundsMax.x) / 2, g.boundsMax.y, (g.boundsMin.z + g.boundsMax.z) / 2))
                guard simd_distance(top, eye) < 8, simd_dot(top - eye, forward) > 0.1,
                      let point = arView.project(top), arView.bounds.contains(point) else { continue }
                // A tap here counts as ours until the host says otherwise.
                let finder = details.foundBy ?? (actor.isFound ? squadMe : nil)
                let tag: ChameleonTags.Tag
                if let finder {
                    let who = finder == squadMe ? "You" : tagName(finder)
                    tag = .init(id: actor.id, point: point, name: "\(who) found \(whose(details.owner))",
                                colour: Color(uiColor: squadColours[finder] ?? .white), kind: .found)
                } else if actor.isMarked {
                    let owner = details.owner == squadMe ? "Yours" : "\(tagName(details.owner))'s"
                    tag = .init(id: actor.id, point: point, name: "\(owner) · not found",
                                colour: Color(uiColor: squadColours[details.owner] ?? .white), kind: .notFound)
                } else {
                    tag = .init(id: actor.id, point: point, name: "Yours", colour: Hunt.paper, kind: .mine)
                }
                list.append(tag)
            }
        }
        tags.show(list)
    }

    /// A player's name on a tag: short enough that "… found …'s" fits over a chameleon.
    private func tagName(_ player: UUID) -> String {
        let name = squadNames[player] ?? ""
        return name.count > 10 ? String(name.prefix(9)) + "…" : name
    }

    private func whose(_ owner: UUID) -> String {
        owner == squadMe ? "yours" : "\(tagName(owner))'s"
    }

    static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func matrix(_ a: [Float]) -> simd_float4x4? {
        guard a.count == 16 else { return nil }
        return simd_float4x4(columns: (SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
                                       SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
    }

    /// The hunt: this player's chameleons keep what they learned; everyone's get hunted,
    /// at the host's difficulty — the same call, with the same numbers, as Swarm's hunt.
    func beginSquadHunt(difficulty: HuntDifficulty) {
        squadTapLock = nil
        applyHuntDifficulty(difficulty)
        scatter.prepareForHunt(livingStrength: huntLivingStrength)
        setMode(.hunting)
        captureHuntMap()
    }

    /// Between rounds: everything off the stage, the shared session kept running so
    /// nobody has to sync again.
    func clearSquadRound() {
        for anchor in squadLocalAnchors.values { arView.session.remove(anchor: anchor) }
        squadLocalAnchors = [:]
        squadAnchors = [:]
        placedFromSpot = []
        settleOffsets = [:]
        squadGaveUp = false
        tags.clear()
        scatter.clear()
        forgetHuntMap(sessionRestarted: false)
        setMode(.showing)
    }

    fileprivate func squadAnchorsChanged(_ anchors: [ARAnchor]) {
        guard squadMode else { return }
        for anchor in anchors {
            if anchor is ARParticipantAnchor, let session = anchor.sessionIdentifier, session != localSessionID {
                if !metSessions.contains(session) { metSessions.insert(session) }
                continue
            }
            if anchor.name?.hasPrefix(Self.roomPrefix) == true {
                placeRoomMap()
                continue
            }
            if anchor.name?.hasPrefix(Self.originPrefix) == true {
                // The host's reference point: here once this device has synced with the host.
                guard squadOriginID == nil || squadOriginID == anchor.identifier else { continue }
                squadOriginID = anchor.identifier
                squadOrigin = anchor.transform
                replaceFromSpots()
                placeRoomMap()
                continue
            }
            guard let name = anchor.name, name.hasPrefix(Self.squadPrefix),
                  let id = UUID(uuidString: String(name.dropFirst(Self.squadPrefix.count))) else { continue }
            squadAnchors[id] = anchor.transform
            if scatter.actor(id) != nil {
                placedFromSpot.remove(id)
                let mine = squadDetails[id]?.owner == squadMe || squadLocalAnchors[id] != nil
                scatter.move(id, to: mine ? anchor.transform : settled(anchor.transform, id: id))
            } else if let details = squadDetails[id], details.owner != squadMe {
                // The details arrived before the anchor did: make it now, as things stand.
                syncSquad(chameleons: Array(squadDetails.values), phase: squadPhase, colours: squadColours,
                          names: squadNames, gaveUp: squadGaveUp, showMine: squadShowMine, seeking: squadSeeking)
            }
        }
    }

    // MARK: - Sharing the room map (squads where not everyone has LiDAR)

    private static let roomPrefix = "room:"
    /// The anchor this device's room map is measured from, if it's the one mapping.
    private var roomAnchor: ARAnchor?
    /// A map that arrived before its anchor did.
    private var pendingRoom: RoomMesh?
    /// Someone else's map of the room, in this device's coordinates.
    private var roomMap: TriangleBVH?
    @Published private(set) var hasRoomMap = false

    // What hides chameleons on a device without LiDAR: the flat surfaces ARKit has found
    // here (tables, walls, counters) plus a squad-mate's room map if there is one. Not the
    // sofa or the lamp — ARKit only finds flat things without LiDAR — but a chameleon
    // under a table or round a wall does hide.
    private var occluders: TriangleBVH?
    private var roomTriangles: (v0: [Vec3], v1: [Vec3], v2: [Vec3]) = ([], [], [])
    private var planeTriangles: (v0: [Vec3], v1: [Vec3], v2: [Vec3]) = ([], [], [])
    private var lastPlaneRefresh: TimeInterval = 0
    private var occluderBuild: Task<Void, Never>?

    /// This device maps the room for the others: drops the anchor the map is measured from.
    func beginRoomScan() {
        guard Self.isLiDARAvailable, squadMode, roomAnchor == nil,
              let camera = arView.session.currentFrame?.camera.transform else { return }
        let anchor = ARAnchor(name: Self.roomPrefix + UUID().uuidString,
                              transform: simd_float4x4(translation: camera.translation))
        arView.session.add(anchor: anchor)
        roomAnchor = anchor
    }

    /// The room as this device's LiDAR has mapped it so far, packed to send, and how many
    /// triangles that is.
    func roomMapData() async -> (data: Data, triangles: Int)? {
        guard let frame = arView.session.currentFrame else { return nil }
        // Measured from the host's reference point when there is one — every device synced
        // with the host has that — otherwise from this device's own room anchor.
        guard let referenceID = squadOriginID ?? roomAnchor?.identifier,
              let anchorToWorld = frame.anchors.first(where: { $0.identifier == referenceID })?.transform
                ?? (roomAnchor?.identifier == referenceID ? roomAnchor?.transform : nil) else { return nil }
        let triangles = MeshExtractor.worldTriangles(from: frame.anchors.compactMap { $0 as? ARMeshAnchor },
                                                     near: anchorToWorld.translation, radius: 7)
        guard !triangles.v0.isEmpty else { return nil }
        let id = referenceID
        let count = triangles.v0.count
        let data = await Task.detached(priority: .utility) {
            let worldToAnchor = anchorToWorld.inverse
            let mesh = RoomMesh(anchor: id, v0: triangles.v0.map { worldToAnchor.transformPoint($0) },
                                v1: triangles.v1.map { worldToAnchor.transformPoint($0) },
                                v2: triangles.v2.map { worldToAnchor.transformPoint($0) })
            return RoomShare.encode(mesh)
        }.value
        return data.map { ($0, count) }
    }

    /// A map from the device that has LiDAR. Devices with their own LiDAR don't need it.
    func receiveRoom(_ data: Data) {
        guard squadMode, !Self.isLiDARAvailable else { return }
        Task {
            guard let mesh = await Task.detached(priority: .utility, operation: { RoomShare.decode(data) }).value else { return }
            pendingRoom = mesh
            placeRoomMap()
        }
    }

    /// Puts a received map into this device's coordinates, once its anchor has arrived.
    private func placeRoomMap() {
        guard let mesh = pendingRoom,
              let anchor = arView.session.currentFrame?.anchors.first(where: { $0.identifier == mesh.anchor }) else { return }
        pendingRoom = nil
        let anchorToWorld = anchor.transform
        Task {
            let (map, world) = await Task.detached(priority: .utility) { () -> (TriangleBVH, (v0: [Vec3], v1: [Vec3], v2: [Vec3])) in
                let world = (v0: mesh.v0.map { anchorToWorld.transformPoint($0) },
                             v1: mesh.v1.map { anchorToWorld.transformPoint($0) },
                             v2: mesh.v2.map { anchorToWorld.transformPoint($0) })
                return (TriangleBVH(v0: world.v0, v1: world.v1, v2: world.v2), world)
            }.value
            guard squadMode else { return }
            roomMap = map
            roomTriangles = world
            rebuildOccluders()
            if !hasRoomMap { hasRoomMap = true }
        }
    }

    /// Collects the flat surfaces ARKit has found, now and then.
    private func refreshPlaneOccluders(_ frame: ARFrame) {
        guard !Self.isLiDARAvailable, frame.timestamp - lastPlaneRefresh > 1.5 else { return }
        lastPlaneRefresh = frame.timestamp
        var found: (v0: [Vec3], v1: [Vec3], v2: [Vec3]) = ([], [], [])
        for plane in frame.anchors.compactMap({ $0 as? ARPlaneAnchor }) {
            let corners = plane.geometry.vertices.map { plane.transform.transformPoint($0) }
            let indices = plane.geometry.triangleIndices
            for i in stride(from: 0, to: indices.count - 2, by: 3) {
                found.v0.append(corners[Int(indices[i])])
                found.v1.append(corners[Int(indices[i + 1])])
                found.v2.append(corners[Int(indices[i + 2])])
            }
        }
        guard found.v0.count != planeTriangles.v0.count || found.v0.first != planeTriangles.v0.first else { return }
        planeTriangles = found
        rebuildOccluders()
    }

    private func rebuildOccluders() {
        let room = roomTriangles, planes = planeTriangles
        occluderBuild?.cancel()
        guard !room.v0.isEmpty || !planes.v0.isEmpty else { occluders = nil; return }
        occluderBuild = Task {
            let built = await Task.detached(priority: .utility) {
                TriangleBVH(v0: room.v0 + planes.v0, v1: room.v1 + planes.v1, v2: room.v2 + planes.v2)
            }.value
            guard !Task.isCancelled else { return }
            occluders = built
        }
    }

    private func clearRoomMap() {
        roomAnchor = nil
        pendingRoom = nil
        roomMap = nil
        roomTriangles = ([], [], [])
        rebuildOccluders()
        hasRoomMap = false
    }

    /// Done hiding: every chameleon keeps what it has learned and carries on adapting
    /// at the round's strength.
    func finishScatterHiding() {
        scatter.prepareForHunt(livingStrength: huntLivingStrength)
        setMode(.showing)
        // From here on they have to stay exactly where they are, whatever happens to the
        // device while it's handed over.
        captureHuntMap()
    }

    /// Back from the handoff screen to drop more.
    func resumeScatterHiding() {
        forgetHuntMap(sessionRestarted: false)
        scatter.resumeHiding()
        setMode(.placing)
    }

    /// Whether the hunt clock should run: the chameleons have to be where they were hidden.
    var isHuntLive: Bool {
        scatterMode ? !trackingGuard.hidden : characterStatus == .visible
    }
    private var trackingIsNormal = true

    /// Called when the AR view is put back on screen.
    func viewDidMount() {
        guard relocalizationPending else { return }
        // Give RealityKit a moment to finish re-attaching the view before restarting the session.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if relocalizationPending { startLocating(.resume) }
        }
    }

    func setMode(_ newMode: Mode) {
        if newMode == .placing, mode != .placing { aim.reset() }
        mode = newMode
        ghost.isEnabled = newMode == .placing || newMode == .scanning
        // No LiDAR wireframe while scanning any more: it made the most important step
        // of the game look like a developer tool. The ring says everything it did.
        arView.debugOptions.remove(.showSceneUnderstanding)
        if newMode != .scanning { scanRing.hide() }
        if newMode != .placing { probe = nil }
        if newMode != .showing { offscreenDirection = nil }
        refreshGhost()
    }

    // MARK: - Placement

    /// Anchors the hiding spot where the ghost is. Returns false if the reticle isn't on a usable surface.
    func confirmPlacement() -> Bool {
        guard mode == .placing, let frame = ghostFrame, probe?.isPlaceable == true,
              let surface = probe?.surface else { return false }

        var placement = frame
        var snapped = false
        if characterStatus == .replacing, let result = snapToScannedSurroundings(placement) {
            // The room around this spot matches the scan: put the character back exactly
            // where (and facing how) it was, rather than approximately by hand.
            placement = result.transform
            snapped = true
            snapMessage = String(format: "Snapped onto your scanned spot (%.0f cm, %.0f°)",
                                 result.moved * 100, abs(result.yawCorrection) * 180 / .pi)
        }

        removeHideAnchors()
        let anchor = ARAnchor(name: Self.anchorName, transform: placement)
        arView.session.add(anchor: anchor)
        hideAnchor = anchor
        hideSurface = surface

        if characterStatus == .replacing {
            // Placed by hand: the scanned surroundings only vouch for it if it snapped back.
            scanMatchesSpot = snapped
            if !snapped { snapMessage = "Placed by hand" }
            attachCharacter(to: anchor)
            setMode(.showing)
            Task { await captureWorldMap() }
        } else {
            collector.reset(anchorToWorld: frame)
            keyframeCount = 0
            coverage = collector.coverage
            // The ring sits just outside the chameleon.
            scanRing.reset()
            scanRing.place(at: placement, radius: max(0.12, 0.16 * characterScale))
            ringProgress = 0
            scanNudge = nil
            scanStalled = false
            scanStartedAt = 0
        }
        return true
    }

    func cancelPlacement() {
        removeHideAnchors()
        hideAnchor = nil
        ghostFrame = nil
        keyframeCount = 0
        coverage = [Bool](repeating: false, count: KeyframeCollector.bucketCount)
    }

    /// Removes our anchor plus any copy restored from a world map, so a later map
    /// never contains two hiding spots.
    private func removeHideAnchors() {
        if let hideAnchor { arView.session.remove(anchor: hideAnchor) }
        for anchor in arView.session.currentFrame?.anchors ?? [] where anchor.name == Self.anchorName {
            arView.session.remove(anchor: anchor)
        }
    }

    private func updateProbe(frame: ARFrame) {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard center.x > 0, let ray = arView.ray(through: center) else { return }

        var position: Vec3
        var normal: Vec3
        if let hit = arView.scene.raycast(origin: ray.origin, direction: ray.direction, length: 5,
                                          query: .nearest, mask: .sceneUnderstanding, relativeTo: nil).first {
            position = hit.position
            normal = hit.normal
        } else if let room = roomMap, let hit = room.intersect(origin: ray.origin, direction: simd_normalize(ray.direction), tMax: 5) {
            // No LiDAR here, but a squad-mate's map of the room: any surface will do.
            position = ray.origin + simd_normalize(ray.direction) * hit.t
            normal = simd_normalize(simd_cross(room.v1[hit.triangle] - room.v0[hit.triangle],
                                               room.v2[hit.triangle] - room.v0[hit.triangle]))
        } else if let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first {
            position = hit.worldTransform.translation
            normal = simd_normalize(hit.worldTransform.yAxis)
        } else {
            probe = Probe(surface: nil, isPlaceable: false)
            ghostFrame = nil
            aim.reset()
            let eye = frame.camera.transform.translation
            let ahead = eye - simd_normalize(frame.camera.transform.zAxis) * 0.7 - Vec3(0, 0.08, 0)
            floatingFrame = SurfaceFrame.anchorTransform(position: ahead, normal: [0, 1, 0], kind: .floor, viewerPosition: eye)
                * SurfaceFrame.yaw(placementYaw)
            refreshGhost()
            return
        }
        floatingFrame = nil

        let cameraPosition = frame.camera.transform.translation
        if simd_dot(normal, cameraPosition - position) < 0 { normal = -normal }
        let surface = SurfaceFrame.classify(normal: normal)

        if characterStatus != .replacing {
            // Keep the pose compatible with the surface under the reticle. (When
            // re-placing a painted character its pose is fixed.)
            if let surface, pose.surface != surface {
                pose = surface == .wall ? .clinging : lastFloorPose
            }
            if pose.surface == .floor { lastFloorPose = pose }
        }

        // Filtered, so the preview (and where "Hide here" puts it) stays put in a shaky hand.
        let steady = aim.update(position: position, normal: normal, kind: surface ?? .floor,
                                viewer: cameraPosition, time: frame.timestamp)
        ghostFrame = SurfaceFrame.anchorTransform(position: steady.position, normal: steady.normal,
                                                  kind: surface ?? .floor, viewerPosition: steady.position + steady.facing)
            * SurfaceFrame.yaw(placementYaw)
        // (In Swarm and Squad, nowhere is placeable while the device doesn't know where it is.)
        let placeable = surface != nil && surface == pose.surface && simd_distance(position, cameraPosition) < 4
            && !(scatterMode && trackingGuard.hidden)
        if let share = Self.unsureDepthShare(frame) {
            shininess += (share - shininess) * 0.15
        }
        let shiny = probe?.looksShiny == true ? shininess > 0.3 : shininess > 0.5
        let newProbe = Probe(surface: surface, isPlaceable: placeable, looksShiny: shiny)
        if newProbe != probe { probe = newProbe }
        refreshGhost()
    }

    /// Smoothed share of the depth sensor's readings around the reticle it isn't sure of.
    private var shininess: Float = 0

    /// The LiDAR sensor can't get a clean reading off glossy, glass and mirror-like
    /// surfaces (and very dark ones) and says so in its confidence map. Those are exactly
    /// the spots where a chameleon gives itself away: their look changes with every step
    /// the seeker takes, and no fixed colour can follow. So the placement screens use this
    /// to suggest somewhere matte instead.
    private static func unsureDepthShare(_ frame: ARFrame) -> Float? {
        guard let map = (frame.sceneDepth ?? frame.smoothedSceneDepth)?.confidenceMap else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map)
        // A patch round the middle of the view, where the reticle is.
        let halfW = width / 12, halfH = height / 10
        var unsure = 0, total = 0
        for y in (height / 2 - halfH)..<(height / 2 + halfH) {
            for x in (width / 2 - halfW)..<(width / 2 + halfW) {
                total += 1
                if base[y * stride + x] < UInt8(ARConfidenceLevel.medium.rawValue) { unsure += 1 }
            }
        }
        return total > 0 ? Float(unsure) / Float(total) : nil
    }

    private func refreshGhost() {
        let frame: simd_float4x4?
        switch mode {
        case .placing: frame = ghostFrame ?? floatingFrame
        case .scanning: frame = hideAnchor?.transform
        default: frame = nil
        }
        let local = simd_float4x4(translation: [0, SurfaceFrame.surfaceOffset, 0]) * simd_float4x4(uniformScale: characterScale)
        // Lots of them: the chameleon itself, in colour, is the only thing following the aim.
        if scatterMode {
            ghost.isEnabled = false
            scatter.showPreview(pose: pose, transform: mode == .placing ? frame.map { $0 * local } : nil,
                                placeable: probe?.isPlaceable == true && scatter.count < ScatterStage.maximum)
            return
        }
        guard let frame else {
            ghost.isEnabled = false
            return
        }
        let valid = mode == .scanning || probe?.isPlaceable == true

        guard let mesh = ghostMeshes[pose] else {
            ghost.isEnabled = false
            return
        }
        ghost.isEnabled = true
        // Rebuilding the model every frame was part of what made placing feel laggy.
        if ghostKey?.pose != pose || ghostKey?.valid != valid {
            ghost.model = ModelComponent(mesh: mesh, materials: [valid ? Self.ghostMaterials.valid : Self.ghostMaterials.invalid])
            ghostKey = (pose, valid)
        }
        ghost.transform = Transform(matrix: frame * local)
    }


    // MARK: - Scanning

    func finishScan() -> ScanCapture? {
        guard let hideAnchor, let frame = arView.session.currentFrame else { return nil }
        // ARKit may have refined the anchor since placement.
        let anchorToWorld = frame.anchors.first { $0.identifier == hideAnchor.identifier }?.transform ?? hideAnchor.transform
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let triangles = MeshExtractor.worldTriangles(from: meshAnchors, near: anchorToWorld.translation,
                                                     radius: SceneExtraction.cropRadius + 0.25)
        spotPhoto = Self.photo(of: anchorToWorld.transformPoint([0, 0.05, 0]), from: collector.keyframes)
        return ScanCapture(keyframes: collector.keyframes, worldV0: triangles.v0, worldV1: triangles.v1,
                           worldV2: triangles.v2, anchorToWorld: anchorToWorld, surface: hideSurface)
    }

    /// Saves ARKit's map of the room (including the hide anchor) so the spot can be
    /// found again after the AR view has been off screen. Returns false if ARKit
    /// couldn't produce one.
    @discardableResult
    func captureWorldMap() async -> Bool {
        let result: UncheckedSendable<ARWorldMap?> = await withCheckedContinuation { continuation in
            // @Sendable: ARKit may answer on its own queue.
            arView.session.getCurrentWorldMap { @Sendable map, error in
                if let error { print("World map capture failed: \(error.localizedDescription)") }
                continuation.resume(returning: UncheckedSendable(value: map))
            }
        }
        if let map = result.value, map.anchors.contains(where: { $0.name == Self.anchorName }) {
            worldMap = map
            return true
        }
        return false
    }

    /// The keyframe that looks most directly at the spot, as a reminder photo.
    private static func photo(of spot: Vec3, from keyframes: [Keyframe]) -> UIImage? {
        let best = keyframes.max { a, b in
            simd_dot(-a.cameraToWorld.zAxis, simd_normalize(spot - a.position))
                < simd_dot(-b.cameraToWorld.zAxis, simd_normalize(spot - b.position))
        }
        guard let frame = best,
              let provider = CGDataProvider(data: Data(frame.rgba) as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: - The scanning ring

    /// Starts the scan over on the same spot.
    func restartScan() {
        guard mode == .scanning, let hideAnchor else { return }
        collector.reset(anchorToWorld: hideAnchor.transform)
        keyframeCount = 0
        coverage = collector.coverage
        scanRing.reset()
        ringProgress = 0
        scanNudge = nil
        scanStalled = false
        scanStartedAt = 0
    }

    /// What to say when there's nothing to put a chameleon on under the aim.
    var noSurfaceHint: String {
        Self.isLiDARAvailable ? "Point at something flat" : "Sweep slowly over a floor or table"
    }

    /// Why the scan hasn't worked, for the message when it doesn't (nil when it's fine).
    var scanProblem: KeyframeCollector.Problem? { collector.mainProblem }

    /// Lights the ticks on the side a keyframe was just taken from. The ring only ever shows
    /// what's really been captured: it used to light up for any look at the spot, so a fast
    /// walk round could fill it while every blurred frame was thrown away, and the scan
    /// then failed at "100%".
    private func fillScanRing(from cameraPosition: Vec3) {
        guard mode == .scanning, let hideAnchor else { return }
        let anchorToWorld = arView.session.currentFrame?.anchors.first { $0.identifier == hideAnchor.identifier }?.transform
            ?? hideAnchor.transform
        let local = anchorToWorld.inverse.transformPoint(cameraPosition)
        guard simd_length(Vec2(local.x, local.z)) > 0.04 else { return }
        if scanRing.fill(towards: atan2(local.z, local.x), spread: 2) {
            ringProgress = scanRing.progress
            lastRingGrowthAt = arView.session.currentFrame?.timestamp ?? lastRingGrowthAt
            tickHaptic.impactOccurred(intensity: 0.5)
        }
    }

    /// Nudges the player while scanning: where to stand, and what's spoiling the pictures.
    private func updateScanRing(frame: ARFrame) {
        guard let hideAnchor else { return }
        let anchorToWorld = frame.anchors.first { $0.identifier == hideAnchor.identifier }?.transform ?? hideAnchor.transform
        let spot = anchorToWorld.transformPoint([0, 0.04, 0])
        let eye = frame.camera.transform.translation
        let local = anchorToWorld.inverse.transformPoint(eye)
        let distance = simd_length(local)
        let planar = simd_length(Vec2(local.x, local.z))

        if scanStartedAt == 0 { scanStartedAt = frame.timestamp; lastRingGrowthAt = frame.timestamp }
        let scanning = frame.timestamp - scanStartedAt
        let stalled = (scanning > 9 && frame.timestamp - lastRingGrowthAt > 4) || scanning > 20
        if stalled != scanStalled { scanStalled = stalled }

        let nudge: String?
        if distance < 0.18 {
            nudge = "Back up a little"
        } else if distance > 2.8 {
            nudge = "Come a bit closer"
        } else if let onScreen = arView.project(spot),
                  !arView.bounds.insetBy(dx: arView.bounds.width * 0.12, dy: arView.bounds.height * 0.12).contains(onScreen) {
            nudge = "Keep it in the middle of the screen"
        } else if hideSurface == .wall && planar < distance * 0.22 {
            nudge = "Now move to the side"
        } else if let latest = collector.latestProblem, frame.timestamp - latest.at < 0.6 {
            nudge = Self.nudge(for: latest.problem)
        } else {
            nudge = nil
        }
        if nudge != scanNudge { scanNudge = nudge }
    }

    private static func nudge(for problem: KeyframeCollector.Problem) -> String? {
        switch problem {
        case .tooFast: return "Slow down"
        case .tooDark: return "Needs more light"
        case .lostTracking: return "Hold steady"
        case .offCentre: return "Keep it in the middle of the screen"
        case .tooClose: return "Back up a little"
        case .tooFar: return "Come a bit closer"
        case .spotMoved: return "The spot moved. Hide it on something still"
        case .blocked: return "Something's in the way"
        }
    }

    // MARK: - Showing the painted character

    /// The scanned room, used to compare the scan's colors against the live camera.
    func setScene(_ scene: HideScene) {
        hideScene = scene
        scanMatchesSpot = true
        // Worked out once: the shape the spot search matches against, spread across
        // surface orientations so a small object's edges count for as much as the floor.
        scanFingerprint = SpotRegistration.samplePoints(from: scene.environment)
        lighting.reset()
    }

    /// Prepares the painted character for AR and starts finding the hiding spot.
    /// The character appears once ARKit has recognized the scanned room.
    func presentCharacter(geometry: CharacterGeometry, pixels: [UInt8]) {
        do {
            try presenter.load(geometry: geometry, pixels: pixels)
        } catch {
            print("Couldn't build the AR character: \(error)")
            return
        }
        presenter.scale = characterScale
        pose = geometry.pose
        presenter.hide()
        characterStatus = .locating
        locatingSince = Date()
        setMode(.showing)
        stage = .resume
        stageStarted = Date()
        relocalizationPending = true
        searchCandidate = nil
        searchState = .looking
        if arView.window != nil { viewDidMount() }
    }

    /// Starts (or escalates) the hunt for the hiding spot.
    private func startLocating(_ newStage: LocatingStage) {
        relocalizationPending = false
        guard let base = configuration else { return }
        presenter.hide()
        stage = newStage
        stageStarted = Date()
        sawRelocalizingState = false
        if locatingSince == nil { locatingSince = Date() }
        characterStatus = .locating

        switch newStage {
        case .resume:
            // No reset: the session keeps its own (much richer) map of the room and its
            // anchors, and ARKit relocalizes by itself if tracking was interrupted.
            arView.session.run(base)
        case .worldMap:
            guard let worldMap else {
                // Nothing saved to match against: go straight to placing it by hand.
                beginReplacement()
                return
            }
            let configuration = base.copy() as! ARWorldTrackingConfiguration
            configuration.initialWorldMap = worldMap
            hideAnchor = nil
            arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    private func tryAttachCharacter(_ frame: ARFrame) {
        if case .limited(.relocalizing) = frame.camera.trackingState { sawRelocalizingState = true }
        let inStage = Date().timeIntervalSince(stageStarted)

        guard case .normal = frame.camera.trackingState else {
            // Resuming rarely stays stuck; reloading the saved map can, so move on.
            if stage == .resume, inStage > 6, worldMap != nil { startLocating(.worldMap) }
            spotIssue = "Point at the spot you scanned"
            return
        }

        // After reloading the saved map, "normal" only means the room was recognized if
        // ARKit went through relocalizing first. Attaching before that puts the character
        // at the map's coordinates inside a brand new coordinate system — a random spot,
        // often under the floor.
        if stage == .worldMap, !sawRelocalizingState {
            spotIssue = "Recognizing the room — point at the spot you scanned"
            return
        }
        guard let anchor = frame.anchors.first(where: { $0.name == Self.anchorName }) ?? hideAnchor else {
            if stage == .resume, inStage > 6, worldMap != nil { startLocating(.worldMap) }
            return
        }

        // Check the spot really is a surface, facing the way it did when it was placed.
        // A relocalization that lands off fails this. The longer it takes, the more
        // slack it gets: a character slightly out of place beats no character at all.
        let tolerance: Float = inStage < 6 ? 0.10 : 0.25
        switch surfaceCheck(for: anchor.transform, tolerance: tolerance) {
        case .onSurface(let corrected):
            guard spotMatchesScan(corrected) else {
                spotIssue = "This doesn't look like the room around your hiding spot yet"
                escalateOrSettle(inStage: inStage, anchor: anchor)
                return
            }
            spotIssue = nil
            attachCharacter(to: anchor, transform: corrected)
        case .noSurfaceYet:
            spotIssue = "Looking at the hiding spot…"
            escalateOrSettle(inStage: inStage, anchor: anchor)
        case .wrongPlace(let distance):
            spotIssue = String(format: "The spot doesn't line up yet (%.0f cm off a surface)", distance * 100)
            escalateOrSettle(inStage: inStage, anchor: anchor)
        }
    }

    /// Recognizing the room from the saved map only works from roughly where it was
    /// scanned, and nobody comes back at that angle. Meanwhile `searchForSpot` is
    /// matching the scan against the live mesh every half second, which doesn't care
    /// where you stand — so the job here is mostly to stay out of its way.
    ///
    /// In particular: reloading the saved map resets tracking and throws away every mesh
    /// anchor the session has built, which is exactly what the shape search needs. Only
    /// do that when the session has nothing to offer anyway.
    private func escalateOrSettle(inStage: TimeInterval, anchor: ARAnchor) {
        let sessionIsHealthy = arView.session.currentFrame.map {
            if case .normal = $0.camera.trackingState { return true } else { return false }
        } ?? false
        switch stage {
        case .resume where inStage > 8 && worldMap != nil && !sessionIsHealthy:
            startLocating(.worldMap)
        case .resume where inStage > 25, .worldMap where inStage > 20:
            beginReplacement()
            spotIssue = "Point at your hiding spot and tap Put It Here — or keep pointing and it will find it itself"
        default:
            break
        }
    }

    private enum SurfaceCheck {
        /// The reconstructed mesh hasn't reached the spot yet.
        case noSurfaceYet
        case wrongPlace(Float)
        /// Good, with the transform snapped onto the surface.
        case onSurface(simd_float4x4)
    }

    /// Looks for a real surface where the hiding spot claims to be, by casting a short
    /// ray back along the spot's own "up" direction (the surface normal it was placed on).
    private func surfaceCheck(for transform: simd_float4x4, tolerance: Float = 0.10) -> SurfaceCheck {
        let origin = transform.translation
        let up = simd_normalize(transform.yAxis)
        let start = origin + up * 0.3
        let hits = arView.scene.raycast(origin: start, direction: -up, length: 0.6,
                                        query: .nearest, mask: .sceneUnderstanding, relativeTo: nil)
        guard let hit = hits.first else { return .noSurfaceYet }

        let offset = simd_dot(hit.position - origin, up)   // + = surface is above the spot (sunk in)
        guard abs(offset) <= tolerance, abs(simd_dot(simd_normalize(hit.normal), up)) > 0.7 else {
            return .wrongPlace(abs(offset))
        }
        // Snap onto the surface so it never sits buried in the floor or floating.
        var corrected = transform
        corrected.columns.3 = SIMD4<Float>(origin + up * offset, 1)
        return .onSurface(corrected)
    }

    /// ARKit sometimes re-establishes where it is (after tracking degrades in a tight
    /// space, say) and every anchor's coordinates shift with it. Small corrections are
    /// what we want; a sudden jump means the character would teleport — usually to some
    /// unrelated spot on the floor — so check it before following, and if it doesn't hold
    /// up, hide the character and find the spot properly instead.
    private func followAnchor(_ anchor: ARAnchor, frame: ARFrame) {
        let cameraPosition = frame.camera.transform.translation
        let cameraMoved = lastCameraPosition.map { simd_distance($0, cameraPosition) } ?? 0
        lastCameraPosition = cameraPosition

        let jump = simd_distance(anchor.transform.translation, presenter.anchorTransform.translation)
        guard jump > 0.15, jump > cameraMoved * 3 else {
            presenter.updateAnchor(anchor.transform)
            return
        }

        // A jump is only trusted when the spot still sits on a surface and the room
        // around it still matches the scan.
        if case .onSurface(let corrected) = surfaceCheck(for: anchor.transform), spotMatchesScan(anchor.transform) {
            presenter.updateAnchor(corrected, force: true)
            spotIssue = nil
            return
        }

        print("Rejected a \(Int(jump * 100)) cm anchor jump; re-finding the hiding spot.")
        presenter.hide()
        characterStatus = .locating
        locatingSince = Date()
        stage = .resume
        stageStarted = Date()
        sawRelocalizingState = false
        spotIssue = "Tracking jumped — finding the spot again"
    }

    /// Fits the scanned surroundings onto what LiDAR sees now, so a hand-placed
    /// character lands exactly where it was hidden — including its facing — without
    /// needing the camera back at the angle it was scanned from.
    private func snapToScannedSurroundings(_ transform: simd_float4x4) -> SpotRegistration.Result? {
        guard let hideScene, let frame = arView.session.currentFrame else { return nil }
        let scanPoints = SpotRegistration.samplePoints(from: hideScene.environment)
        guard scanPoints.count >= 40 else { return nil }
        let live = MeshExtractor.worldVertices(from: frame.anchors.compactMap { $0 as? ARMeshAnchor },
                                               near: transform.translation, radius: 1.3)
        guard live.count >= 200 else { return nil }
        let result = SpotRegistration.refine(scanPoints: scanPoints,
                                             live: SpotRegistration.PointGrid(points: live),
                                             initial: transform)
        guard let result, result.isGood else { return nil }
        return result
    }

    // MARK: - Finding the hiding spot again, by shape

    /// Everything one attempt needs, in plain values so it can run off the main actor.
    private struct SpotSearch: Sendable {
        let scanPoints: [Vec3]
        let live: [Vec3]
        let candidates: [simd_float4x4]
        let maxTranslation: Float
    }

    private nonisolated static func bestMatch(_ input: SpotSearch) -> SpotRegistration.Result? {
        let grid = SpotRegistration.PointGrid(points: input.live)
        var best: SpotRegistration.Result?
        for candidate in input.candidates {
            guard let result = SpotRegistration.refine(scanPoints: input.scanPoints, live: grid,
                                                       initial: candidate,
                                                       maxTranslation: input.maxTranslation) else { continue }
            guard result.isGood else { continue }
            if result.meanError < (best?.meanError ?? .greatestFiniteMagnitude) { best = result }
        }
        return best
    }

    /// Looks for the hiding spot in what LiDAR can see right now, by matching the shape
    /// of the scanned surroundings against the live mesh.
    ///
    /// This is the way back to the spot, not a fallback. Recognizing the room from the
    /// saved world map only works from roughly where it was scanned, and nobody comes
    /// back at that angle — they sit down to paint, then return from wherever they are.
    /// Shape doesn't care where you stand: point the iPad at the area and the scan is
    /// fitted onto the room around it, which also recovers the facing.
    private func searchForSpot(_ frame: ARFrame) {
        guard searchTask == nil, presenter.geometry != nil, !scanFingerprint.isEmpty,
              Date().timeIntervalSince(lastSearchAt) > 0.4 else { return }
        guard case .normal = frame.camera.trackingState else { return }

        var candidates: [simd_float4x4] = []
        var centre: Vec3?

        // Wherever the iPad is pointed, tried at every facing — the scan itself decides
        // which one is right.
        let screenCentre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if screenCentre.x > 0, let ray = arView.ray(through: screenCentre),
           let hit = arView.scene.raycast(origin: ray.origin, direction: ray.direction, length: 5,
                                          query: .nearest, mask: .sceneUnderstanding, relativeTo: nil).first {
            var normal = hit.normal
            let eye = frame.camera.transform.translation
            if simd_dot(normal, eye - hit.position) < 0 { normal = -normal }
            if let kind = SurfaceFrame.classify(normal: normal), kind == hideSurface {
                let base = SurfaceFrame.anchorTransform(position: hit.position, normal: normal,
                                                        kind: kind, viewerPosition: eye)
                for turn in 0..<8 { candidates.append(base * SurfaceFrame.yaw(Float(turn) * .pi / 4)) }
                centre = hit.position
            }
        }
        // Plus wherever ARKit still thinks the spot is, if the session kept tracking.
        if let hideAnchor {
            candidates.append(hideAnchor.transform)
            centre = centre ?? hideAnchor.transform.translation
        }
        guard let centre, !candidates.isEmpty else {
            if searchState != .looking { searchState = .looking }
            return
        }

        let live = MeshExtractor.worldVertices(from: frame.anchors.compactMap { $0 as? ARMeshAnchor },
                                               near: centre, radius: 1.6)
        guard live.count >= 250 else {
            if searchState != .looking { searchState = .looking }
            return
        }

        lastSearchAt = Date()
        // Room to walk to the right spot from a rough aim, but not so much that it can
        // wander off to a different piece of furniture.
        let input = SpotSearch(scanPoints: scanFingerprint, live: live, candidates: candidates,
                               maxTranslation: 0.35)
        searchTask = Task { [weak self] in
            let match = await Task.detached(priority: .userInitiated) { ARSessionController.bestMatch(input) }.value
            await MainActor.run { self?.finishSearch(match) }
        }
    }

    private func finishSearch(_ match: SpotRegistration.Result?) {
        searchTask = nil
        guard characterStatus == .locating || characterStatus == .replacing else { return }
        // A good fit isn't enough on its own: a single frame of half-built mesh can
        // produce one. The same spot has to come back twice in a row.
        guard let match, match.meanError < 0.035, match.inlierRatio > 0.6 else {
            searchCandidate = nil
            if searchState != .looking { searchState = .looking }
            return
        }
        if let previous = searchCandidate, Date().timeIntervalSince(previous.at) < 3,
           simd_distance(previous.transform.translation, match.transform.translation) < 0.06,
           simd_dot(simd_normalize(previous.transform.zAxis), simd_normalize(match.transform.zAxis)) > 0.97 {
            adoptFoundSpot(match)
        } else {
            searchCandidate = (match.transform, Date())
            searchState = .confirming
        }
    }

    private func adoptFoundSpot(_ match: SpotRegistration.Result) {
        searchCandidate = nil
        searchState = .found(moved: match.moved, turned: abs(match.yawCorrection) * 180 / .pi)
        snapMessage = "Found your hiding spot"
        spotIssue = nil
        scanMatchesSpot = true
        removeHideAnchors()
        let anchor = ARAnchor(name: Self.anchorName, transform: match.transform)
        arView.session.add(anchor: anchor)
        setMode(.showing)
        attachCharacter(to: anchor)
    }

    /// Does the room around this spot still look like the room that was scanned?
    /// Samples the scanned crop and checks each piece against the live LiDAR mesh, which
    /// rejects a relocalization that lands somewhere plausible but wrong (a random patch
    /// of floor has no wall or table where the scan says there is one).
    private func spotMatchesScan(_ transform: simd_float4x4, minimumScore: Double = 0.45) -> Bool {
        guard scanMatchesSpot, let scene = hideScene else { return true }
        let environment = scene.environment
        guard environment.triangleCount > 60 else { return true }

        var checked = 0
        var matched = 0
        let step = max(1, environment.triangleCount / 40)
        for triangle in stride(from: 0, to: environment.triangleCount, by: step) {
            let centroid = (environment.bvh.v0[triangle] + environment.bvh.v1[triangle] + environment.bvh.v2[triangle]) / 3
            guard simd_length(centroid) < 0.8 else { continue }
            let normal = environment.faceNormals[triangle]
            let world = transform.transformPoint(centroid)
            let worldNormal = simd_normalize(transform.transformDirection(normal))
            checked += 1
            let hits = arView.scene.raycast(origin: world + worldNormal * 0.12, direction: -worldNormal,
                                            length: 0.24, query: .nearest, mask: .sceneUnderstanding, relativeTo: nil)
            if let hit = hits.first, simd_distance(hit.position, world) < 0.07 { matched += 1 }
        }
        guard checked >= 8 else { return true }   // not enough mesh yet to judge
        return Double(matched) / Double(checked) >= minimumScore
    }

    /// Keeps the character resting on the surface as ARKit refines its map.
    private func nudgeOntoSurface(_ frame: ARFrame) {
        guard characterStatus == .visible, frame.timestamp - lastSurfaceCheck > 2 else { return }
        lastSurfaceCheck = frame.timestamp
        guard case .normal = frame.camera.trackingState else { return }
        // Only small sinking is corrected. In a tight gap — a character wedged against a
        // wall — a bigger "correction" is just as likely to shove it somewhere wrong.
        switch surfaceCheck(for: presenter.anchorTransform, tolerance: 0.05) {
        case .onSurface(let corrected):
            spotIssue = nil
            presenter.updateAnchor(corrected, force: true)
        case .wrongPlace(let distance):
            spotIssue = distance > 0.3 ? String(format: "Drifted %.0f cm off the surface", distance * 100) : nil
        case .noSurfaceYet:
            break
        }
    }

    private func attachCharacter(to anchor: ARAnchor, transform: simd_float4x4? = nil) {
        hideAnchor = anchor
        presenter.show(at: transform ?? anchor.transform)
        characterStatus = .visible
        locatingSince = nil
        // Save a fresh map now that the room is recognized, for the next trip to the studio.
        Task { await captureWorldMap() }
    }

    /// Fallback when the spot can't be found: re-place the painted character wherever the hider points.
    func beginReplacement() {
        guard presenter.geometry != nil else { return }
        snapMessage = nil
        placementYaw = 0
        searchCandidate = nil
        relocalizationPending = false
        presenter.hide()
        characterStatus = .replacing
        locatingSince = nil
        setMode(.placing)
    }

    /// Gives up on re-placing and tries to find the original spot again.
    func retryRelocalization() {
        guard presenter.geometry != nil else { return }
        characterStatus = .locating
        locatingSince = Date()
        setMode(.showing)
        startLocating(.resume)
    }

    /// Restores the painted look after a reveal or highlight.
    func restoreCharacterMaterial() {
        presenter.restore()
    }

    func setHighlighted(_ highlighted: Bool) {
        presenter.setHighlighted(highlighted)
    }

    /// Flash and bounce so both players can see where it was.
    func revealCharacter() {
        presenter.reveal()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard mode == .placing, gesture.state == .changed else { return }
        let factor = Float(gesture.scale)
        gesture.scale = 1
        if characterStatus != .replacing {
            characterScale = min(max(characterScale * factor, CharacterPose.scaleRange.lowerBound),
                                 CharacterPose.scaleRange.upperBound)
        }
    }

    @objc private func handleTwist(_ gesture: UIRotationGestureRecognizer) {
        guard mode == .placing, gesture.state == .changed else { return }
        var yaw = placementYaw - Float(gesture.rotation)
        gesture.rotation = 0
        while yaw > .pi { yaw -= 2 * .pi }
        while yaw < -.pi { yaw += 2 * .pi }
        placementYaw = yaw
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and twist together, like on a photo.
        (gestureRecognizer is UIPinchGestureRecognizer && other is UIRotationGestureRecognizer)
            || (gestureRecognizer is UIRotationGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    @objc private func handleRotate(_ gesture: UIPanGestureRecognizer) {
        guard mode == .placing else { return }
        let translation = gesture.translation(in: arView)
        gesture.setTranslation(.zero, in: arView)
        // Wrap into -180...180 so the slider and the drag always agree.
        var yaw = placementYaw + Float(translation.x) * 0.006
        while yaw > .pi { yaw -= 2 * .pi }
        while yaw < -.pi { yaw += 2 * .pi }
        placementYaw = yaw
    }

    /// Degrees, for the rotation slider.
    var placementYawDegrees: Float {
        get { placementYaw * 180 / .pi }
        set { placementYaw = newValue * .pi / 180 }
    }

    // MARK: - Hunting

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if scatterMode {
            // Swarm and Squad take a tap the same way: the same reach for the difficulty,
            // and a tap on one that's already lit up (found, or your own) is neither a
            // find nor a miss.
            // Nothing counts while the chameleons are hidden for lost tracking.
            guard mode == .hunting, !trackingGuard.hidden else { return }
            let point = gesture.location(in: arView)
            let reach = CGFloat(huntDifficulty.tapReach)
            if squadMode, let lock = squadTapLock, Date() < lock {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                return
            }
            if let actor = scatter.unfoundActor(near: point, excludingOwner: squadMode ? squadMe : nil, reach: reach) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if squadMode { onSquadClaim?(actor.id) } else { onSeekerFoundOne?(actor) }
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                guard !scatter.touchesLitUp(near: point, reach: reach) else { return }
                if squadMode { onSquadMiss?() } else { onSeekerMiss?() }
            }
            return
        }
        guard mode == .hunting, characterStatus == .visible else { return }
        if hitsCharacter(near: gesture.location(in: arView)) {
            setMode(.showing)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSeekerHit?()
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSeekerMiss?()
        }
    }

    /// Exact ray cast against the character mesh, with a small ring of extra probes
    /// so a well-hidden (tiny on screen) character doesn't demand pixel-perfect taps.
    private func hitsCharacter(near point: CGPoint) -> Bool {
        guard let geometry = presenter.geometry, presenter.isShowing else { return false }
        let worldToCharacter = presenter.characterToWorld.inverse

        var probes = [point]
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            probes.append(CGPoint(x: point.x + cos(angle) * 24, y: point.y + sin(angle) * 24))
        }
        for probe in probes {
            guard let ray = arView.ray(through: probe) else { continue }
            let origin = worldToCharacter.transformPoint(ray.origin)
            let direction = simd_normalize(worldToCharacter.transformDirection(ray.direction))
            if geometry.bvh.intersect(origin: origin, direction: direction) != nil { return true }
        }
        return false
    }

    /// Screen-edge arrow toward the character while the hider checks it in AR, or toward
    /// the nearest hidden one when the clue drops in the "lots of them" game.
    private func updateOffscreenDirection() {
        var target: Vec3?
        var onScreen = false
        if scatterMode {
            if pointsToNearestHidden, mode == .hunting,
               let actor = scatter.nearestUnfound(to: arView.cameraTransform.translation, excludingOwner: squadMe) {
                target = actor.worldCenter
                onScreen = actor.isOnScreen(in: arView)
            }
        } else if characterStatus == .visible, mode == .showing, let center = presenter.worldCenter {
            target = center
            onScreen = presenter.isOnScreen
        }
        let inView = scatterMode && target != nil && onScreen
        if hintTargetInView != inView { hintTargetInView = inView }
        guard let center = target else {
            if offscreenDirection != nil { offscreenDirection = nil }
            return
        }
        if onScreen {
            if offscreenDirection != nil { offscreenDirection = nil }
            return
        }
        // Direction in the on-screen camera's frame (+X right, +Y up); flip y for screen space.
        let local = arView.cameraTransform.matrix.inverse.transformPoint(center)
        offscreenDirection = atan2(Double(-local.y), Double(local.x))
    }

    // MARK: - Reset

    // MARK: - Matching the screen's colours

    /// Once a round, as soon as tracking is steady: measure how a texture reaches the
    /// screen, so chameleons can be stored as what shows as the camera's colours
    /// (DisplayCurve). A few tries if a reading doesn't make sense, then the fitted curve
    /// stands.
    private func calibrateColoursIfDue(_ frame: ARFrame) {
        guard scatterMode, SceneAssets.usesMeasuredCurve, !colourCalibrating, !colourMeasuredThisRound,
              colourAttempts < 5, let since = trackingGoodSince, frame.timestamp - since > 0.6,
              frame.timestamp - lastColourTry > 2.5, arView.bounds.width > 200, arView.window != nil else { return }
        lastColourTry = frame.timestamp
        calibrateColours()
    }

    /// Where a point of the view is at `depth` metres in front of the camera, in the
    /// camera's own coordinates.
    private func cameraPoint(through point: CGPoint, depth: Float) -> SIMD3<Float>? {
        guard let ray = arView.ray(through: point) else { return nil }
        let worldToCamera = arView.cameraTransform.matrix.inverse
        let origin = worldToCamera.transformPoint(ray.origin)
        let direction = worldToCamera.transformDirection(ray.direction)
        guard direction.z < -1e-4 else { return nil }
        return origin + direction * ((-depth - origin.z) / direction.z)
    }

    /// The strip's texture: each of DisplayCurve.patchLevels as an 8×8 block of grey.
    private static let patchPixels: [UInt8] = {
        var pixels: [UInt8] = []
        for _ in 0..<8 {
            for level in DisplayCurve.patchLevels {
                for _ in 0..<8 { pixels.append(contentsOf: [UInt8(level), UInt8(level), UInt8(level), 255]) }
            }
        }
        return pixels
    }()

    /// Shows a small strip of known greys, drawn exactly as a chameleon's texture is,
    /// fixed to the camera along the very bottom edge of the view for a fraction of a
    /// second, takes a picture of what the view shows, and reads the strip back.
    private func calibrateColours() {
        let bounds = arView.bounds
        let cells = DisplayCurve.patchLevels.count
        let cell: CGFloat = 16
        let y = bounds.maxY - 12
        let left = CGPoint(x: bounds.midX - cell * CGFloat(cells) / 2, y: y)
        let right = CGPoint(x: bounds.midX + cell * CGFloat(cells) / 2, y: y)
        guard let l = cameraPoint(through: left, depth: 0.3), let r = cameraPoint(through: right, depth: 0.3),
              simd_distance(l, r) > 0.005,
              let texture = try? SceneAssets.staticTexture(rgba: Self.patchPixels, width: cells * 8, height: 8) else {
            colourAttempts += 1
            return
        }
        let width = simd_distance(l, r)
        let strip = ModelEntity(mesh: .generatePlane(width: width, height: width / Float(cells)),
                                materials: [SceneAssets.camouflage(texture)])
        // Facing the camera, its length along the line between the two points.
        let x = simd_normalize(r - l), z = SIMD3<Float>(0, 0, 1)
        strip.transform = Transform(matrix: simd_float4x4(xAxis: x, yAxis: simd_cross(z, x), zAxis: z, origin: (l + r) / 2))
        let anchor = AnchorEntity(.camera)
        anchor.addChild(strip)
        arView.scene.addAnchor(anchor)
        colourPatch = anchor
        colourCalibrating = true
        Task { @MainActor [weak self] in
            // A few frames, so it has been drawn.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.colourCalibrating, self.colourPatch === anchor else { return }
            let frame = self.arView.session.currentFrame.map { UncheckedSendable(value: $0) }
            // RealityKit hands the picture back on its own terms: sendable, and hopping
            // to the main actor itself.
            self.arView.snapshot(saveToHDR: false) { @Sendable image in
                let picture = UncheckedSendable(value: image)
                Task { @MainActor [weak self] in
                    self?.finishColourCalibration(picture.value, frame: frame?.value, left: left, right: right, anchor: anchor)
                }
            }
            // If the picture never comes, the strip mustn't stay on screen.
            try? await Task.sleep(for: .seconds(1.5))
            if self.colourPatch === anchor {
                self.finishColourCalibration(nil, frame: nil, left: left, right: right, anchor: anchor)
            }
        }
    }

    private func finishColourCalibration(_ image: UIImage?, frame: ARFrame?, left: CGPoint, right: CGPoint, anchor: AnchorEntity) {
        anchor.removeFromParent()
        guard colourPatch === anchor else { return }
        colourPatch = nil
        colourCalibrating = false
        let bounds = arView.bounds
        guard let cg = image?.cgImage, let picture = Bitmap(cg), bounds.width > 0, bounds.height > 0 else {
            colourAttempts += 1
            colourNote = "fitted curve (no picture to measure from)"
            return
        }
        let scale = SIMD2<Float>(Float(picture.width) / Float(bounds.width), Float(picture.height) / Float(bounds.height))
        func shown(at point: CGPoint, radius: Float) -> SIMD3<Float>? {
            picture.mean(x: Float(point.x) * scale.x, y: Float(point.y) * scale.y, radius: radius * scale.x)
        }
        let cells = DisplayCurve.patchLevels.count
        var readings: [SIMD3<Float>] = []
        for i in 0..<cells {
            let t = (CGFloat(i) + 0.5) / CGFloat(cells)
            guard let value = shown(at: CGPoint(x: left.x + (right.x - left.x) * t, y: left.y + (right.y - left.y) * t), radius: 4) else { continue }
            readings.append(value)
        }
        // Which end of the strip its first cell lands on depends on how the plane is
        // mapped; a ramp that falls is one read from the other end.
        if let first = readings.first, let last = readings.last, first.y > last.y { readings.reverse() }
        let list = readings.map { String(Int($0.y)) }.joined(separator: " ")
        guard readings.count == cells, var curve = DisplayCurve(levels: DisplayCurve.patchLevels, shown: readings) else {
            colourAttempts += 1
            colourNote = "fitted curve (reading \(colourAttempts) made no sense: \(list))"
            return
        }
        // A reading has to agree with what the playtest screenshots showed for bright
        // greys; one that doesn't is a picture of something other than the screen.
        guard DisplayCurve.agreesWithScreenshots(levels: DisplayCurve.patchLevels, shown: readings) else {
            colourAttempts += 1
            colourNote = "fitted curve (reading \(colourAttempts) disagrees with the screenshots: \(list))"
            return
        }

        // And the camera picture itself: is it shown as its pixels say? Compared at a
        // grid of points away from the strip and from any chameleon.
        var feed = SIMD3<Float>(repeating: 1)
        var feedNote = "feed not compared"
        if let frame {
            let avoid = scatter.actors.compactMap { arView.project($0.worldCenter) }
            var ratios: [[Float]] = [[], [], []]
            for row in 0..<4 {
                for column in 0..<6 {
                    let point = CGPoint(x: bounds.minX + bounds.width * (CGFloat(column) + 0.5) / 6,
                                        y: bounds.minY + bounds.height * (0.12 + 0.16 * CGFloat(row)))
                    guard !avoid.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 110 }),
                          let seen = shown(at: point, radius: 9),
                          let sampled = CameraColorSampler.color(from: frame, at: point, viewportSize: bounds.size,
                                                                 orientation: interfaceOrientation, patchRadius: 14) else { continue }
                    let camera = sampled * 255
                    // Away from black and white, where a ratio means something.
                    guard simd_reduce_min(camera) > 40, simd_reduce_max(camera) < 232, simd_reduce_max(seen) < 240 else { continue }
                    for channel in 0..<3 { ratios[channel].append(seen[channel] / camera[channel]) }
                }
            }
            if ratios[1].count >= 8 {
                var gain = SIMD3<Float>(repeating: 1), steady = true
                for channel in 0..<3 {
                    let sorted = ratios[channel].sorted()
                    gain[channel] = sorted[sorted.count / 2]
                    if sorted[sorted.count * 3 / 4] - sorted[sorted.count / 4] > 0.08 { steady = false }
                }
                // Only if the points agree (the camera wasn't moving) and it's a small
                // correction; a big one means the comparison went wrong, not the picture.
                if steady, simd_reduce_min(gain) > 0.86, simd_reduce_max(gain) < 1.14 {
                    feed = gain
                    feedNote = String(format: "feed shown ×%.2f", gain.y)
                } else {
                    feedNote = String(format: "feed comparison unsteady (×%.2f, not used)", gain.y)
                }
            }
        }
        curve = curve.matchingFeed(gain: feed)

        let levels = DisplayCurve.patchLevels
        colourNote = "measured: " + [1, 4, 7].map { "\(levels[$0])→\(Int(readings[$0].y))" }.joined(separator: " ") + " · " + feedNote
        SceneAssets.measuredCurve = SceneAssets.measuredCurve.map { $0.blended(with: curve) } ?? curve
        colourMeasuredThisRound = true
        redrawChameleons()
    }

    /// A picture's pixels, to read colours out of.
    private struct Bitmap {
        let width: Int, height: Int
        private let pixels: [UInt8]

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            width = w
            height = h
            pixels = data
        }

        /// The mean colour (0…255) of the square of `radius` pixels round a point.
        func mean(x: Float, y: Float, radius: Float) -> SIMD3<Float>? {
            let cx = Int(x.rounded()), cy = Int(y.rounded()), r = max(1, Int(radius.rounded()))
            guard cx - r >= 0, cy - r >= 0, cx + r < width, cy + r < height else { return nil }
            var sum = SIMD3<Float>(repeating: 0)
            for py in (cy - r)...(cy + r) {
                for px in (cx - r)...(cx + r) {
                    let i = (py * width + px) * 4
                    sum += SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                }
            }
            let side = Float(2 * r + 1)
            return sum / (side * side)
        }
    }

    // MARK: - Keeping its place in the room

    /// Each frame, in Swarm and Squad: whether the chameleons can be shown, and whether
    /// the device has been blind long enough that it must find its place again.
    private func guardTracking(_ frame: ARFrame) {
        guard scatterMode else { return }
        let quality: TrackingGuard.Quality
        switch frame.camera.trackingState {
        case .normal: quality = .good
        case .limited(.excessiveMotion), .limited(.insufficientFeatures): quality = .shaky
        case .limited, .notAvailable: quality = .blind
        }
        // From the handoff or the hunt's start (when there's a map to go back to) until
        // the round is cleared away; while hiding, only blindness hides anything.
        let guarding = huntMap != nil || mode == .hunting
        if trackingGuard.update(quality, time: frame.timestamp, guarding: guarding) { refindRoom() }
        if quality == .good {
            if isRefindingRoom { isRefindingRoom = false }
            if trackingGoodSince == nil { trackingGoodSince = frame.timestamp }
        } else {
            trackingGoodSince = nil
        }
        let dt = Float(min(max(frame.timestamp - lastFadeTime, 0), 0.1))
        lastFadeTime = frame.timestamp
        trackingFade += ((trackingGuard.hidden ? 0 : 1) - trackingFade) * min(1, dt * 6)

        calibrateColoursIfDue(frame)

        // Keep the saved map fresh while all's well: the more of the room it has seen,
        // the quicker the device finds its place in it.
        if guarding, let since = trackingGoodSince, frame.timestamp - since > 3,
           frame.timestamp - lastHuntMapTime > 20,
           frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending {
            captureHuntMap()
        }
    }

    /// Saves ARKit's map of the room as it is now, with every chameleon where it should
    /// be. Called as hiding ends, when a hunt is paused, and now and then during a hunt.
    func captureHuntMap() {
        guard Self.isARAvailable, sessionStarted, scatterMode, !trackingGuard.hidden, trackingIsNormal else { return }
        let round = huntMapRound
        lastHuntMapTime = arView.session.currentFrame?.timestamp ?? lastHuntMapTime
        // @Sendable, and hopping to the main actor itself: ARKit answers on its own queue.
        arView.session.getCurrentWorldMap { @Sendable [weak self] map, _ in
            guard let map else { return }
            let box = UncheckedSendable(value: map)
            Task { @MainActor in
                guard let self, self.huntMapRound == round else { return }
                self.huntMap = box.value
            }
        }
    }

    /// The saved map no longer describes this round (it's over, or more are being hidden).
    /// `sessionRestarted`: the AR session itself is starting afresh, so nothing is known
    /// about its tracking yet. Otherwise what's known stands: if the device is in the
    /// middle of finding its place again, it still is.
    private func forgetHuntMap(sessionRestarted: Bool) {
        huntMapRound += 1
        huntMap = nil
        lastHuntMapTime = 0
        guard sessionRestarted else { return }
        isRefindingRoom = false
        trackingGuard.reset()
        trackingFade = 1
    }

    /// The device has been blind long enough to have been moved without knowing it (put
    /// down, camera covered, picked up somewhere else). Start again from the saved map:
    /// ARKit then shows nothing as tracked until it has matched the camera's view against
    /// that map, and when it has, the room's coordinates are the saved ones, so every
    /// chameleon is back on its spot. Until then they stay hidden and the hunt's clock
    /// (Swarm) holds.
    private func refindRoom() {
        guard let map = huntMap, let base = configuration,
              let next = base.copy() as? ARWorldTrackingConfiguration else { return }
        next.initialWorldMap = map
        arView.session.run(next, options: [.resetTracking, .removeExistingAnchors])
        // A new session as far as the other devices in a squad are concerned.
        sessionID = arView.session.identifier
        previousCameraTransform = nil
        cameraMotion = 0
        isRefindingRoom = true
    }

    // MARK: - Reset

    func reset() {
        presenter.hide()
        scatter.clear()
        forgetHuntMap(sessionRestarted: true)
        colourPatch?.removeFromParent()
        colourPatch = nil
        colourCalibrating = false
        colourMeasuredThisRound = false
        colourAttempts = 0
        for anchor in swarmAnchors.values { arView.session.remove(anchor: anchor) }
        swarmAnchors = [:]
        roomEase = 0
        scatterMode = false
        pointsToNearestHidden = false
        snapMessage = nil
        placementYaw = 0
        ringProgress = 0
        scanNudge = nil
        scanStalled = false
        scanStartedAt = 0
        scanRing.reset()
        scanRing.hide()
        scanFingerprint = []
        searchCandidate = nil
        searchState = .idle
        searchTask?.cancel()
        searchTask = nil
        characterStatus = .none
        worldMap = nil
        spotPhoto = nil
        hideScene = nil
        lighting.reset()
        relocalizationPending = false
        locatingSince = nil
        cancelPlacement()
        collector.reset(anchorToWorld: matrix_identity_float4x4)
        arView.environment.sceneUnderstanding.options = [.collision]
        setMode(.idle)
    }

    // MARK: - ARSessionDelegate

    // Delivered on the main queue (delegateQueue is nil). ARFrame isn't Sendable,
    // so assert isolation instead of hopping actors.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        guardTracking(frame)
        updateTrackingHint(frame.camera.trackingState)
        if frame.worldMappingStatus != mappingStatus { mappingStatus = frame.worldMappingStatus }
        maintainSquadOrigin(frame)
        updateTags(frame)

        switch mode {
        case .placing:
            if frame.timestamp - lastProbeTime > 1.0 / 20 {
                lastProbeTime = frame.timestamp
                updateProbe(frame: frame)
            }
            // Even while it's being put back by hand, keep looking for the real spot —
            // if it turns up, it just goes back by itself.
            if characterStatus == .replacing { searchForSpot(frame) }
            // Chameleons already dropped keep melting into the room while more go down.
            if scatterMode {
                updateActors(frame)
                scatter.animatePreview()
            }
        case .scanning:
            collector.consider(frame)
            updateScanRing(frame: frame)

            if frame.timestamp - lastMeshCountTime > 0.5, let anchor = hideAnchor {
                lastMeshCountTime = frame.timestamp
                meshTriangleCount = MeshExtractor.countTriangles(in: frame.anchors.compactMap { $0 as? ARMeshAnchor },
                                                                 near: anchor.transform.translation,
                                                                 radius: SceneExtraction.cropRadius)
            }
        case .showing, .hunting:
            if characterStatus == .locating {
                searchForSpot(frame)
                if !relocalizationPending { tryAttachCharacter(frame) }
            }
            if characterStatus == .visible, let hideAnchor,
               let current = frame.anchors.first(where: { $0.identifier == hideAnchor.identifier }) {
                followAnchor(current, frame: frame)
            }
            if !scatterMode { nudgeOntoSurface(frame) }
            updateLighting(frame)
            updateActors(frame)
            if frame.timestamp - lastArrowTime > 0.1 {
                lastArrowTime = frame.timestamp
                updateOffscreenDirection()
            }
        case .idle:
            break
        }

        if showDiagnostics, frame.timestamp - lastDiagnosticsTime > 0.25 {
            lastDiagnosticsTime = frame.timestamp
            updateDiagnostics(frame)
        }
    }

    // MARK: - Keeping every chameleon hidden and in colour

    /// Every chameleon in the room right now, whichever game this is.
    private var actors: [ChameleonActor] {
        var list = scatter.actors
        if !scatterMode, characterStatus == .visible, let actor = presenter.actor { list.append(actor) }
        return list
    }

    private func updateActors(_ frame: ARFrame) {
        // How fast the iPad is moving: show/hide decisions hold still while it does.
        let camera = frame.camera.transform
        if let previous = previousCameraTransform, frame.timestamp > previousCameraTime {
            let dt = Float(frame.timestamp - previousCameraTime)
            let linear = simd_distance(camera.translation, previous.translation) / dt
            let turn = acos(min(1, max(-1, simd_dot(camera.zAxis, previous.zAxis)))) / dt
            cameraMotion += (linear + turn - cameraMotion) * min(1, dt / 0.15)
        }
        previousCameraTransform = camera
        previousCameraTime = frame.timestamp

        let actors = self.actors
        guard !actors.isEmpty else { return }
        refreshPlaneOccluders(frame)
        settleOthers(frame.timestamp)

        // How much of each the seeker gets to see: none while the device doesn't know
        // where it is (trackingFade, from guardTracking), and in a hunt, less the further
        // away.
        // How spread out they are, which makes a big space a little easier (RoomSpread).
        // They hardly move, so now and then is plenty.
        if frame.timestamp - lastSpreadTime > 1 {
            lastSpreadTime = frame.timestamp
            roomEase = RoomSpread.ease(width: RoomSpread.width(of: actors.map(\.worldCenter)))
        }
        let difficulty = activeDifficulty
        for actor in actors {
            var fade: Float = scatterMode ? trackingFade : 1
            var camouflage: Float = 1
            var tell: Float = 0
            let own = squadMode && actor.owner == squadMe
            if mode == .hunting, !actor.isMarked, !own {
                let distance = simd_distance(camera.translation, actor.worldCenter)
                fade *= DistanceFade.opacity(distance: distance, roomEase: roomEase, difficulty: difficulty)
                camouflage = RoomSpread.camouflageScale(distance: distance, roomEase: roomEase)
                // Swarm and Squad only: Paint & Hide's one chameleon is as its hider painted it.
                if scatterMode { tell = difficulty.tell(distance: distance) }
            }
            actor.viewFade = fade
            actor.camouflageScale = camouflage
            actor.tell = tell
            actor.livingAdaptRate = difficulty.adaptRate
        }

        // Coverage — how much of each chameleon, and of each chunk of it, is behind
        // something real — plus how shiny the surface behind it is. One pass over the
        // depth map serves every chameleon, about 40 times a second: a quick sweep past
        // a wall has to hide it within a frame or two.
        var coverages: [UUID: Float] = [:]
        var chunkCoverages: [UUID: [Float?]] = [:]
        if frame.timestamp - lastCoverageTime > 1.0 / 40, let depth = depthCells(frame) {
            lastCoverageTime = frame.timestamp
            let worldToCamera = camera.inverse
            for actor in actors where !actor.isMarked && actor.isOnScreen(in: arView) {
                let characterToCamera = worldToCamera * actor.characterToWorld
                let mask = CharacterMask.build(mesh: actor.geometry.mask, characterToCamera: characterToCamera,
                                               intrinsics: depth.intrinsics, grid: depth.cells.grid)
                if let unsure = OcclusionCoverage.unsureShare(behind: mask, in: depth.cells) { actor.noteShine(unsure) }
                guard actor.occlusionEnabled else { continue }
                coverages[actor.id] = OcclusionCoverage.coverage(of: mask, in: depth.cells)
                let eye = actor.characterToWorld.inverse.transformPoint(camera.translation)
                chunkCoverages[actor.id] = actor.chunks.coverage(characterToCamera: characterToCamera, eyeInCharacter: eye,
                                                                 intrinsics: depth.intrinsics, cells: depth.cells)
            }
        } else if frame.sceneDepth == nil, let room = occluders, frame.timestamp - lastCoverageTime > 1.0 / 15 {
            // No depth sensor: what's in front comes from the flat surfaces found here and a
            // squad-mate's map of the room.
            lastCoverageTime = frame.timestamp
            for actor in actors where !actor.isMarked && actor.occlusionEnabled && actor.isOnScreen(in: arView) {
                let chunks = actor.chunks.coverage(characterToWorld: actor.characterToWorld, eye: camera.translation, room: room)
                chunkCoverages[actor.id] = chunks
                let seen = chunks.compactMap { $0 }
                if !seen.isEmpty { coverages[actor.id] = seen.reduce(0, +) / Float(seen.count) }
            }
        }
        // Fades advance every frame so they stay smooth.
        for actor in actors {
            if actor === presenter.actor {
                presenter.updateVisibility(coverage: coverages[actor.id], chunkCoverage: chunkCoverages[actor.id],
                                           motion: cameraMotion, time: frame.timestamp)
            } else {
                actor.updateVisibility(coverage: coverages[actor.id], chunkCoverage: chunkCoverages[actor.id],
                                       motion: cameraMotion, time: frame.timestamp)
            }
        }

        // Living camouflage, several times a second (more often the harder the hunt), from
        // what the camera sees right now. The nearest first: they're the ones being
        // looked at, and each takes a few milliseconds.
        let interval = mode == .hunting ? difficulty.refreshInterval : HuntDifficulty.easy.refreshInterval
        guard !livingFrameInFlight, frame.timestamp - lastLivingTime > interval else { return }
        let living = actors.filter {
            $0.effectiveLivingStrength > 0.02 && !$0.isMarked && !$0.suppressed && !$0.shownAsMine
                && !$0.isRefreshingSkin && $0.isOnScreen(in: arView)
        }
        .sorted { simd_distance_squared($0.worldCenter, camera.translation) < simd_distance_squared($1.worldCenter, camera.translation) }
        guard !living.isEmpty, let snapshot = LiveFrameSnapshot(frame) else { return }
        lastLivingTime = frame.timestamp
        livingFrameInFlight = true
        Task {
            let keyframe = await Task.detached(priority: .userInitiated) { snapshot.keyframe() }.value
            for actor in living { await actor.refreshLiving(from: keyframe) }
            livingFrameInFlight = false
        }
    }

    /// The depth map, reduced to the nearest reading per cell of a coarse grid.
    private func depthCells(_ frame: ARFrame) -> (cells: OcclusionCoverage.Cells, intrinsics: SIMD4<Float>)? {
        guard let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth else { return nil }
        let map = depthData.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowPixels = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        let camera = frame.camera
        let sx = Float(width) / Float(camera.imageResolution.width)
        let sy = Float(height) / Float(camera.imageResolution.height)
        let intrinsics = SIMD4<Float>(camera.intrinsics[0][0] * sx, camera.intrinsics[1][1] * sy,
                                      camera.intrinsics[2][0] * sx, camera.intrinsics[2][1] * sy)
        let depth = UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float32.self), count: rowPixels * height)

        var confidence: UnsafeBufferPointer<UInt8>?
        var confidenceStride = 0
        let confidenceMap = depthData.confidenceMap
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }
        if let confidenceMap, let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap),
           CVPixelBufferGetWidth(confidenceMap) == width, CVPixelBufferGetHeight(confidenceMap) == height {
            confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
            confidence = UnsafeBufferPointer(start: confidenceBase.assumingMemoryBound(to: UInt8.self),
                                             count: confidenceStride * height)
        }
        let cells = OcclusionCoverage.sample(depth: depth, width: width, height: height, stride: rowPixels,
                                             confidence: confidence, confidenceStride: confidenceStride)
        return (cells, intrinsics)
    }

    private var interfaceOrientation: UIInterfaceOrientation {
        arView.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    /// Nudges the paint's brightness and color toward what the camera sees right now.
    private func updateLighting(_ frame: ARFrame) {
        guard characterStatus == .visible, !scatterMode, let hideScene else { return }
        guard lightingMatchEnabled else {
            // The shine measurement rides on the lighting match; without it, no boost.
            presenter.actor?.viewDependence = 0
            return
        }
        if let gain = lighting.update(frame: frame, arView: arView, scene: hideScene,
                                      presenter: presenter, orientation: interfaceOrientation) {
            presenter.applyLighting(gain)
        }
        presenter.actor?.viewDependence = lighting.viewDependence
    }

    private func updateDiagnostics(_ frame: ARFrame) {
        var lines: [String] = []
        lines.append("Build \(AppVersion.label)")
        lines.append("Tracking: \(Self.describe(frame.camera.trackingState)) · map: \(Self.describe(frame.worldMappingStatus)) · saved map: \(worldMap == nil ? "no" : "yes")")
        if scatterMode {
            lines.append("Hunt map: \(huntMap == nil ? "none" : "saved") · chameleons \(trackingGuard.hidden ? "hidden (tracking)" : "shown")\(isRefindingRoom ? " · finding the room again" : "") · \(activeDifficulty.title)")
            lines.append("Colours: " + (SceneAssets.usesMeasuredCurve ? colourNote : "fitted curve (measuring switched off)"))
        }
        lines.append("Character status: \(characterStatus) · mode: \(mode) · finding: \(stage) · relocalized: \(sawRelocalizingState ? "yes" : "not seen")")
        if let spotIssue { lines.append("Spot: \(spotIssue)") }
        lines.append("Spot verified against the scan: \(scanMatchesSpot ? "yes" : "no (placed by hand)")")
        lines.append("Spot search: \(searchState) · \(scanFingerprint.count) scan points")
        if let hideAnchor {
            let inSession = frame.anchors.contains { $0.identifier == hideAnchor.identifier }
            lines.append("Hide anchor in session: \(inSession ? "yes" : "NO")")
        } else {
            lines.append("Hide anchor: none")
        }
        if let entity = presenter.entity, let center = presenter.worldCenter {
            let distance = simd_distance(center, frame.camera.transform.translation)
            let projected = arView.project(center).map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "behind camera"
            lines.append(String(format: "Entity: active %@ · enabled %@ · has model %@ · %.2f m away",
                                entity.isActive ? "yes" : "NO", entity.isEnabled ? "yes" : "NO",
                                entity.model != nil ? "yes" : "NO", distance))
            lines.append("Center projects to \(projected) in \(Int(arView.bounds.width))×\(Int(arView.bounds.height)) · scale \(String(format: "%.2f", presenter.scale))")
        } else {
            lines.append("Entity: not in scene")
        }
        let gain = presenter.lightingGain
        lines.append(String(format: "Lighting match: %@ ×%.2f/%.2f/%.2f from %d samples",
                            lightingMatchEnabled ? "on" : "off", gain.x, gain.y, gain.z, lighting.sampleCount))
        lines.append("Occlusion: \(presenter.occlusionEnabled ? "on" : "off") · depth frames: \(frame.smoothedSceneDepth != nil ? "smoothed" : frame.sceneDepth != nil ? "raw" : "NONE") · camera motion \(String(format: "%.2f", cameraMotion))")
        lines.append(String(format: "Covered: %.0f%% · %@ · %d of %d chunks faded · living colour %.0f%%",
                            presenter.smoothedCoverage * 100, presenter.visibility == .hidden ? "hidden" : "shown",
                            presenter.actor?.hiddenChunkCount ?? 0, presenter.actor?.chunks.count ?? 0,
                            (presenter.actor?.skin.averageWeight ?? 0) * 100))
        if let actor = presenter.actor {
            lines.append(String(format: "Behind it: sensor unsure %.0f%% · differs from scan %.0f%% · living colour now %.0f%%",
                                actor.shine * 100, actor.viewDependence * 100, actor.effectiveLivingStrength * 100))
        }
        if scatterMode { lines.append("Chameleons: \(scatter.count) hidden · \(scatter.foundCount) found") }
        lines.append("Scene understanding: \(arView.environment.sceneUnderstanding.options.contains(.occlusion) ? "collision + occlusion" : "collision only")")
        if let geometry = presenter.geometry {
            lines.append("Paint atlas: \(geometry.atlasWidth)×\(geometry.atlasHeight) · pose \(geometry.pose.rawValue)")
        }
        diagnosticLines = lines
    }

    private static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited (initializing)"
            case .excessiveMotion: return "limited (moving too fast)"
            case .insufficientFeatures: return "limited (not enough detail)"
            case .relocalizing: return "limited (relocalizing)"
            @unknown default: return "limited"
            }
        }
    }

    private static func describe(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "not available"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }

    /// Lets ARKit re-find its bearings after an interruption (e.g. the camera was
    /// covered) instead of resuming with misaligned anchors.
    nonisolated func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        guard let encoded = try? NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true) else { return }
        let critical = data.priority == .critical
        MainActor.assumeIsolated { onCollaborationData?(encoded, critical) }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let box = UncheckedSendable(value: anchors)
        MainActor.assumeIsolated { squadAnchorsChanged(box.value) }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let box = UncheckedSendable(value: anchors)
        MainActor.assumeIsolated {
            squadAnchorsChanged(box.value)
            swarmAnchorsChanged(box.value)
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        // Not the error's own text: players get what to do, not a system message.
        MainActor.assumeIsolated { trackingHint = "The camera stopped · go back and try again" }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { trackingHint = "Camera paused" }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated { trackingHint = nil }
    }

    private func updateTrackingHint(_ state: ARCamera.TrackingState) {
        if case .normal = state { trackingIsNormal = true } else { trackingIsNormal = false }
        let hint: String?
        switch state {
        case .normal: hint = nil
        case .notAvailable: hint = "Starting the camera…"
        case .limited(let reason):
            switch reason {
            case .initializing: hint = "Look around slowly"
            case .excessiveMotion: hint = "Slow down"
            case .insufficientFeatures: hint = "Not enough detail here"
            case .relocalizing:
                hint = isRefindingRoom ? "Look around · finding the room again"
                                       : characterStatus == .locating ? nil : "Finding your place…"
            @unknown default: hint = "Hold steady"
            }
        }
        if hint != trackingHint { trackingHint = hint }
    }

    // MARK: - Debug

    #if DEBUG
    /// Lets the Simulator (which has no AR) show the AR overlays for layout checks.
    func debugScanProgress(_ progress: Float, stalled: Bool = false) {
        ringProgress = progress
        keyframeCount = 8
        scanStalled = stalled
    }

    func debugSetCharacterStatus(_ status: CharacterStatus, locatingFor seconds: TimeInterval = 0) {
        characterStatus = status
        locatingSince = status == .locating ? Date().addingTimeInterval(-seconds) : nil
        diagnosticLines = ["Tracking: normal · map: mapped · saved map: yes", "Character status: \(status) · mode: showing",
                           "Hide anchor in session: yes", "Entity: active yes · enabled yes · has model yes · 1.20 m away",
                           "Center projects to (512, 700) in 1032×1376 · scale 1.00",
                           "Rendering: Painted mesh · Image texture · occlusion off"]
    }
    #endif
}

// MARK: - Mesh extraction

enum MeshExtractor {

    static func worldTriangles(from anchors: [ARMeshAnchor], near center: Vec3,
                               radius: Float) -> (v0: [Vec3], v1: [Vec3], v2: [Vec3]) {
        var a = [Vec3](), b = [Vec3](), c = [Vec3]()
        forEachTriangle(in: anchors, near: center, radius: radius) { p0, p1, p2 in
            a.append(p0); b.append(p1); c.append(p2)
        }
        return (a, b, c)
    }

    /// Sampled mesh vertices near a point, for fitting the scan onto the live room.
    static func worldVertices(from anchors: [ARMeshAnchor], near center: Vec3, radius: Float,
                              sampleEvery: Int = 2) -> [Vec3] {
        var points: [Vec3] = []
        let radiusSquared = radius * radius
        for anchor in anchors {
            let vertices = anchor.geometry.vertices
            guard vertices.format == .float3 else { continue }
            let base = UnsafeRawPointer(vertices.buffer.contents()).advanced(by: vertices.offset)
            let transform = anchor.transform
            for i in stride(from: 0, to: vertices.count, by: max(1, sampleEvery)) {
                let offset = i * vertices.stride
                let local = Vec3(base.load(fromByteOffset: offset, as: Float.self),
                                 base.load(fromByteOffset: offset + 4, as: Float.self),
                                 base.load(fromByteOffset: offset + 8, as: Float.self))
                let world = transform.transformPoint(local)
                if simd_distance_squared(world, center) <= radiusSquared { points.append(world) }
            }
        }
        return points
    }

    static func countTriangles(in anchors: [ARMeshAnchor], near center: Vec3, radius: Float) -> Int {
        var count = 0
        forEachTriangle(in: anchors, near: center, radius: radius) { _, _, _ in count += 1 }
        return count
    }

    private static func forEachTriangle(in anchors: [ARMeshAnchor], near center: Vec3, radius: Float,
                                        _ body: (Vec3, Vec3, Vec3) -> Void) {
        let radiusSquared = radius * radius
        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let vertices = geometry.vertices
            let faces = geometry.faces
            guard vertices.format == .float3, faces.bytesPerIndex == 4, faces.primitiveType == .triangle else { continue }

            let vertexBase = UnsafeRawPointer(vertices.buffer.contents()).advanced(by: vertices.offset)
            var world = [Vec3](repeating: .zero, count: vertices.count)
            for i in 0..<vertices.count {
                let offset = i * vertices.stride
                let local = Vec3(vertexBase.load(fromByteOffset: offset, as: Float.self),
                                 vertexBase.load(fromByteOffset: offset + 4, as: Float.self),
                                 vertexBase.load(fromByteOffset: offset + 8, as: Float.self))
                world[i] = transform.transformPoint(local)
            }

            let indexBase = UnsafeRawPointer(faces.buffer.contents())
            for f in 0..<faces.count {
                let i0 = Int(indexBase.load(fromByteOffset: f * 12, as: UInt32.self))
                let i1 = Int(indexBase.load(fromByteOffset: f * 12 + 4, as: UInt32.self))
                let i2 = Int(indexBase.load(fromByteOffset: f * 12 + 8, as: UInt32.self))
                guard i0 < world.count, i1 < world.count, i2 < world.count else { continue }
                let p0 = world[i0], p1 = world[i1], p2 = world[i2]
                if simd_distance_squared((p0 + p1 + p2) / 3, center) <= radiusSquared {
                    body(p0, p1, p2)
                }
            }
        }
    }
}

// MARK: - SwiftUI bridge

struct ARViewContainer: UIViewRepresentable {
    let controller: ARSessionController

    func makeUIView(context: Context) -> ARView {
        controller.startSessionIfNeeded()
        Task { @MainActor in controller.viewDidMount() }
        return controller.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
