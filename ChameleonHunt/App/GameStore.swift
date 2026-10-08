//
//  GameStore.swift
//  The round's state machine. Two games share the second half:
//
//   one chameleon:  intro → placing → scanning → processing → studio ⇄ arCheck ┐
//   lots of them:   intro → scattering ────────────────────────────────────────┤
//                                                  handoff → seeking ⇄ paused → result
//
//  plus a demo path (intro → processing → studio) that uses a built-in room and
//  needs no LiDAR, so the studio can be tried anywhere, including the Simulator.
//
//  The one-chameleon hunt can only start from the AR check once the character has
//  actually been found at its hiding spot, so the seeker never gets a round with
//  nothing to find.
//

import Combine
import Foundation
import SwiftUI

enum GameConfig {
    static let minimumKeyframes = 4
    static let minimumTriangles = 200

    /// Hunt lengths offered on the start screen, in seconds.
    /// The seeker's time. Longer choices since v6.9: three minutes wasn't enough in a
    /// real house.
    static let huntDurations = [60, 90, 120, 180, 300, 480, 600]
    static let defaultHuntDuration = 120
    /// How strongly the lots-of-them chameleons keep matching the room during the hunt:
    /// most of the way, leaving a faint lag a sharp-eyed seeker can catch. Nudged for the
    /// screen size (see ScreenDifficulty and ARSessionController.swarmHuntStrength).
    static let scatterLivingStrength: Float = 0.75
    /// Paint & Hide's one chameleon during the hunt: a little live colour over the paint job.
    static let classicLivingStrength: Float = 0.35

    /// "1:05" style countdown.
    static func clock(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds)"
    }

    /// Always minutes and seconds ("0:49"), for the camera's readouts.
    static func stopwatch(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

@MainActor
final class GameStore: ObservableObject {

    enum Phase: Equatable {
        case intro
        case placing
        case scanning
        case processing
        case studio
        /// Back in AR after painting: find the spot, check the camouflage.
        case arCheck
        /// Lots of them: dropping chameleons around the room.
        case scattering
        case handoff
        case seeking
        case seekerWon
        case hiderWon
        /// Squad play: several devices, one game (SquadGame runs it).
        case squad

        var isResult: Bool { self == .seekerWon || self == .hiderWon }
    }

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var studio: StudioController?
    @Published private(set) var processingMessage = ""
    @Published private(set) var processingProgress: Float = 0
    @Published private(set) var isSavingScan = false
    @Published private(set) var secondsRemaining = GameConfig.defaultHuntDuration
    @Published private(set) var missCount = 0
    @Published private(set) var isHuntPaused = false
    /// The character is briefly out of the scene while AR re-finds the hiding spot.
    @Published private(set) var isWaitingForSpot = false
    /// A message that needs an answer, shown in the game's own style (UI/Notice.swift).
    @Published var notice: Notice?

    /// Chosen on the start screen and remembered between launches.
    @Published var huntDuration: Int {
        didSet { UserDefaults.standard.set(huntDuration, forKey: "huntDuration") }
    }

    /// Which game this round is.
    @Published private(set) var mode: GameMode = .classic
    /// Lots of them: how many the seeker has found so far.
    @Published private(set) var foundCount = 0
    /// Every round played on this iPad, for the IMG number the camera stamps on the result.
    @Published private(set) var roundNumber = UserDefaults.standard.integer(forKey: "roundNumber")
    /// When the seeker is told what they are looking for.
    @Published var hintTiming: HintTiming {
        didSet { UserDefaults.standard.set(hintTiming.rawValue, forKey: "hintTiming") }
    }
    /// Swarm: how hard the hunt is, picked on SEEKER'S TURN and remembered.
    @Published var swarmDifficulty: HuntDifficulty =
        UserDefaults.standard.string(forKey: "swarmDifficulty").flatMap(HuntDifficulty.init(rawValue:)) ?? .easy {
        didSet { UserDefaults.standard.set(swarmDifficulty.rawValue, forKey: "swarmDifficulty") }
    }
    /// Bumped each time a miss costs the seeker time, for the "-5 s" by the clock.
    @Published private(set) var penaltiesTaken = 0
    /// Coins earned so far in this hunt (they go into the wallet as they're earned).
    @Published private(set) var coinsThisRound = 0

    /// Whether the seeker can use the hint (Settings). There's no waiting for it any more:
    /// it's there from the start, and using it halves the coins from then on.
    var hintsOn: Bool {
        get { hintTiming != .never }
        set { hintTiming = newValue ? .thirtySeconds : .never }
    }
    /// A 3-2-1 before the clock starts, so the seeker is looking at the room — not at the
    /// hider — when it does.
    @Published private(set) var countdown: Int?
    /// True once the seeker has used the hint in this hunt.
    @Published private(set) var hintDropped = false
    /// The Hint key has unlocked (at the time set in Settings); using it is the seeker's call.
    @Published private(set) var hintAvailable = false
    let ar = ARSessionController()
    private(set) lazy var squad = SquadGame(ar: ar, name: playerName)

    /// What other players see this device called in squad games.
    @Published var playerName: String {
        didSet {
            UserDefaults.standard.set(playerName, forKey: "playerName")
            squad.rename(playerName)
        }
    }

    private var clockTask: Task<Void, Never>?
    private var deadline: Date?
    private var pausedRemaining: TimeInterval?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "huntDuration")
        huntDuration = GameConfig.huntDurations.contains(saved) ? saved : GameConfig.defaultHuntDuration
        let savedHint = UserDefaults.standard.object(forKey: "hintTiming") as? Int
        hintTiming = savedHint.flatMap(HintTiming.init(rawValue:)) ?? .thirtySeconds
        let savedName = UserDefaults.standard.string(forKey: "playerName")?.trimmingCharacters(in: .whitespaces) ?? ""
        playerName = savedName.isEmpty ? "Player \(Int.random(in: 10...99))" : savedName
        UserDefaults.standard.set(playerName, forKey: "playerName")
        secondsRemaining = huntDuration
        ar.onSeekerHit = { [weak self] in self?.seekerFound() }
        ar.onSeekerMiss = { [weak self] in self?.seekerMissed() }
        ar.onSeekerFoundOne = { [weak self] actor in self?.seekerFoundOne(actor) }
    }

    var isDemo: Bool { studio?.scene.isDemo ?? false }

    /// Lots of them: how many are hidden this round.
    var hiddenCount: Int { ar.scatter.count }

    /// The hunt's length. With lots of them hidden the seeker gets a little longer
    /// for each one after the first.
    var roundDuration: Int {
        guard mode == .scatter else { return huntDuration }
        return min(900, huntDuration + swarmDifficulty.secondsPerExtra * max(0, hiddenCount - 1))
    }

    // MARK: - Hiding

    private func prepareRound(_ newMode: GameMode) -> Bool {
        // Paint & Hide paints from a 3D scan of the spot, which needs LiDAR. Swarm runs
        // without it, cut down: flat surfaces only, and only people hide them.
        guard ARSessionController.isARAvailable else {
            notice = .needsAR
            return false
        }
        guard newMode == .scatter || ARSessionController.isLiDARAvailable else {
            notice = .needsLiDAR
            return false
        }
        stopClock()
        isHuntPaused = false
        pausedRemaining = nil
        studio = nil
        mode = newMode
        foundCount = 0
        roundNumber += 1
        UserDefaults.standard.set(roundNumber, forKey: "roundNumber")
        missCount = 0
        hintDropped = false
        hintAvailable = false
        ar.reset()
        // Lots of them camouflage themselves — that's the game. The one chameleon is
        // hidden by the hider's paint job: it takes on only a little of the room, and only
        // during the hunt (startHunt), to even out the light the scan couldn't know about.
        ar.huntLivingStrength = newMode == .scatter ? ar.swarmHuntStrength : 0
        ar.presenter.livingStrength = 0
        ar.startNewRound()
        return true
    }

    /// One chameleon, scanned and hand-painted.
    func beginHiding() {
        guard prepareRound(.classic) else { return }
        ar.characterScale = 1
        ar.setMode(.placing)
        phase = .placing
    }

    /// Lots of chameleons, dropped quickly; they camouflage themselves.
    func beginScatter() {
        guard prepareRound(.scatter) else { return }
        ar.beginScatter(scale: 0.8)
        phase = .scattering
    }

    /// Same game again, straight away.
    func playAgain() {
        mode == .scatter ? beginScatter() : beginHiding()
    }

    func dropChameleon() {
        guard phase == .scattering else { return }
        if ar.dropScatterChameleon() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Sound.shared.play(.drop)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            Sound.shared.play(.miss)
        }
    }

    func undoChameleon() {
        guard phase == .scattering else { return }
        ar.undoScatterChameleon()
    }

    func finishScattering() {
        guard phase == .scattering, hiddenCount > 0 else { return }
        ar.finishScatterHiding()
        secondsRemaining = roundDuration
        phase = .handoff
    }

    func placeHere() {
        guard ar.confirmPlacement() else { return }
        ar.setMode(.scanning)
        phase = .scanning
    }

    /// What to tell the hider when a scan didn't get enough, from what spoiled it. The
    /// ring only lights for pictures that were kept, so what's lit is done: carrying on
    /// fills in the rest.
    private func scanTrouble(_ problem: KeyframeCollector.Problem?) -> Notice {
        let (title, message, symbol): (String, String, String) = switch problem {
        case .tooFast: ("Too fast", "Walk round it slowly so the pictures come out sharp.", "hare.fill")
        case .tooDark: ("Too dark", "Turn a light on, or pick a spot with more around it.", "lightbulb.fill")
        case .lostTracking: ("Lost track", "Hold steady and move slowly.", "location.slash.fill")
        case .offCentre: ("Lost sight of it", "Keep the chameleon in the middle of the screen.", "scope")
        case .tooClose: ("Too close", "Stay about an arm's length away.", "arrow.down.right.and.arrow.up.left")
        case .tooFar: ("Too far", "Stay about an arm's length away.", "arrow.up.left.and.arrow.down.right")
        case .spotMoved: ("The spot moved", "Hide it on something that stays still, not a person or a pet.", "figure.walk")
        case .blocked: ("Something's in the way", "Keep hands and things out of the way while you scan.", "hand.raised.fill")
        case nil: ("Not enough yet", "Walk all the way round it.", "arrow.triangle.2.circlepath")
        }
        return Notice(title: title, message: message, systemImage: symbol,
                      primary: .init(title: "Keep scanning", systemImage: "viewfinder") {},
                      secondary: .init(title: "Move it") { [weak self] in self?.backToPlacement() })
    }

    func backToPlacement() {
        ar.cancelPlacement()
        ar.setMode(.placing)
        phase = .placing
    }

    func finishScan() {
        guard !isSavingScan, let capture = ar.finishScan() else { return }
        guard capture.keyframes.count >= GameConfig.minimumKeyframes else {
            notice = scanTrouble(ar.scanProblem)
            return
        }
        guard capture.worldV0.count >= GameConfig.minimumTriangles else {
            // Scanned fine, but there's barely any surface around it: it's on something
            // that moves (a person, a pet) or something ARKit can't map.
            notice = Notice(title: "Can't see the surface",
                            message: "Hide it on something solid that stays still, then walk round it.",
                            systemImage: "square.3.layers.3d.down.right.slash",
                            primary: .init(title: "Move it", systemImage: "hand.point.up.left.fill") { [weak self] in
                                self?.backToPlacement()
                            },
                            secondary: .init(title: "Scan again") { [weak self] in self?.ar.restartScan() })
            return
        }

        let pose = ar.pose
        let scale = ar.characterScale
        isSavingScan = true

        Task {
            // Save ARKit's map of the room while the AR view is still live, so the
            // spot can be found again after painting.
            let savedMap = await ar.captureWorldMap()
            isSavingScan = false
            if !savedMap {
                print("No world map saved; the AR check will fall back to re-placing.")
            }

            ar.setMode(.idle)
            phase = .processing
            processingProgress = 0
            processingMessage = "Looking at the room…"

            let result = await Task.detached(priority: .userInitiated) { [weak self] () -> ScanResult in
                let cropped = SceneExtraction.crop(v0: capture.worldV0, v1: capture.worldV1, v2: capture.worldV2,
                                                   anchorToWorld: capture.anchorToWorld)
                var environment = EnvironmentGeometry(v0: cropped.v0, v1: cropped.v1, v2: cropped.v2)
                await self?.setProcessing("Remembering the colours…", 0)
                KeyframeBaker.bake(&environment, keyframes: capture.keyframes,
                                   worldToAnchor: capture.anchorToWorld.inverse) { progress in
                    Task { @MainActor in self?.processingProgress = progress }
                }
                let worldToAnchor = capture.anchorToWorld.inverse
                let viewpoints = capture.keyframes.map { worldToAnchor.transformPoint($0.position) }
                let scene = HideScene(environment: environment, anchorToWorld: capture.anchorToWorld,
                                      surface: capture.surface, viewpoints: viewpoints, isDemo: false)

                await self?.setProcessing("Waking the chameleon up…", 1)
                return ScanResult(scene: scene, geometry: CharacterGeometry.build(from: CharacterShape.build(pose)))
            }.value

            openStudio(scene: result.scene, geometry: result.geometry, scale: scale)
        }
    }

    func openDemo(surface: SurfaceKind, pose: CharacterPose? = nil) {
        phase = .processing
        processingMessage = "Setting up the demo room…"
        processingProgress = 1
        let chosenPose = pose ?? (surface == .wall ? .clinging : .standing)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                (DemoEnvironment.makeScene(surface: surface),
                 CharacterGeometry.build(from: CharacterShape.build(chosenPose)))
            }.value
            openStudio(scene: result.0, geometry: result.1, scale: 1)
        }
    }

    private func setProcessing(_ message: String, _ progress: Float) {
        processingMessage = message
        processingProgress = progress
    }

    /// What one scan produced.
    private struct ScanResult: Sendable {
        var scene: HideScene
        var geometry: CharacterGeometry
    }

    private func openStudio(scene: HideScene, geometry: CharacterGeometry, scale: Float) {
        do {
            studio = try StudioController(scene: scene, geometry: geometry, scale: scale, initialPixels: nil)
            phase = .studio
        } catch {
            notice = Notice(title: "Couldn't open the studio", message: error.localizedDescription,
                            systemImage: "exclamationmark.triangle.fill")
            phase = scene.isDemo ? .intro : .placing
        }
    }

    // MARK: - Studio <-> AR

    /// Leaves the studio for AR: hands the current paint to the AR view and starts
    /// finding the hiding spot again.
    func placeInAR() {
        guard let studio, !studio.scene.isDemo else { return }
        studio.finishActiveStroke()
        ar.setScene(studio.scene)
        ar.characterScale = studio.characterScale
        ar.presentCharacter(geometry: studio.canvas.geometry, pixels: studio.canvas.pixels)
        phase = .arCheck
    }

    /// The handoff screen's back button: back to hiding, whichever game this is.
    func backFromHandoff() {
        if mode == .scatter {
            stopClock()
            isHuntPaused = false
            ar.resumeScatterHiding()
            phase = .scattering
        } else {
            backToStudio()
        }
    }

    func backToStudio() {
        guard studio != nil else { exitToIntro(); return }
        ar.presenter.livingStrength = 0
        stopClock()
        isHuntPaused = false
        ar.setMode(.idle)
        phase = .studio
    }

    func replaceCharacterHere() {
        ar.beginReplacement()
    }

    func retryFindingSpot() {
        ar.retryRelocalization()
    }

    func readyToSeek() {
        guard phase == .arCheck, ar.characterStatus == .visible else { return }
        ar.restoreCharacterMaterial()
        ar.setMode(.showing)
        secondsRemaining = roundDuration
        phase = .handoff
    }

    // MARK: - Seeking

    func startHunt() {
        guard phase == .handoff else { return }
        missCount = 0
        foundCount = 0
        coinsThisRound = 0
        hintDropped = false
        hintAvailable = hintsOn
        isHuntPaused = false
        isWaitingForSpot = false
        ar.pointsToNearestHidden = false
        ar.restoreCharacterMaterial()
        // Paint & Hide: during the hunt the painted chameleon also takes on a little of the
        // live camera colour behind it, which evens out the light and shadow the scan
        // couldn't know about (playtesters found it stood out). Most of what shows is
        // still the paint job, so painting still matters.
        ar.presenter.livingStrength = mode == .classic ? GameConfig.classicLivingStrength : 0
        if mode == .scatter { ar.applyHuntDifficulty(swarmDifficulty) }
        ar.setMode(.showing)
        phase = .seeking
        secondsRemaining = roundDuration
        countdown = 3
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                self.countdown = n
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Sound.shared.play(.tick)
                try? await Task.sleep(for: .milliseconds(850))
            }
            guard let self, !Task.isCancelled, self.phase == .seeking else { return }
            self.countdown = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Sound.shared.play(.go)
            self.ar.setMode(.hunting)
            self.startClock(seconds: TimeInterval(self.roundDuration))
        }
    }

    /// Stops the clock and hides the view while the players decide what to do.
    func pauseHunt() {
        guard phase == .seeking, !isHuntPaused, let deadline else { return }
        pausedRemaining = max(0, deadline.timeIntervalSinceNow)
        stopClock()
        // The device may be put down while it's paused: save where everything is now, so
        // it can find its place in the room again when it's picked up.
        ar.captureHuntMap()
        ar.setMode(.showing)
        isHuntPaused = true
    }

    func resumeHunt() {
        guard phase == .seeking, isHuntPaused else { return }
        isHuntPaused = false
        ar.setMode(.hunting)
        startClock(seconds: pausedRemaining ?? TimeInterval(roundDuration))
        pausedRemaining = nil
    }

    /// The app went to the background mid-hunt (a call, a notification tapped): stop the
    /// clock rather than let the seeker's time run out while they're away.
    func appWentAway() {
        if phase == .seeking, !isHuntPaused, countdown == nil { pauseHunt() }
    }

    /// Back to the "pass the iPad" screen with a full clock.
    func restartHunt() {
        stopClock()
        isHuntPaused = false
        pausedRemaining = nil
        ar.restoreCharacterMaterial()
        if mode == .scatter { ar.finishScatterHiding() }
        ar.pointsToNearestHidden = false
        ar.setMode(.showing)
        foundCount = 0
        secondsRemaining = roundDuration
        hintDropped = false
        hintAvailable = false
        phase = .handoff
    }

    private func startClock(seconds: TimeInterval) {
        stopClock()
        deadline = Date().addingTimeInterval(seconds)
        secondsRemaining = Int(ceil(seconds))
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard phase == .seeking, !isHuntPaused, let deadline else { return }

        // If AR lost the spot for a moment, hold the clock rather than burning the
        // seeker's time on something they can't possibly find.
        if !ar.isHuntLive {
            self.deadline = deadline.addingTimeInterval(0.2)
            if !isWaitingForSpot { isWaitingForSpot = true }
            return
        }
        if isWaitingForSpot { isWaitingForSpot = false }

        let remaining = max(0, min(roundDuration, Int(ceil(deadline.timeIntervalSinceNow))))
        if remaining != secondsRemaining { secondsRemaining = remaining }

        if remaining == 0 {
            stopClock()
            Sound.shared.play(.lose)
            ar.setMode(.showing)
            if mode == .scatter { ar.scatter.revealUnfound() } else { ar.revealCharacter() }
            phase = .hiderWon
        }
    }

    /// The seeker asks for the hint: where it is (one chameleon) or an arrow to the
    /// nearest one (lots of them). Once per hunt.
    func useHint() {
        guard phase == .seeking, hintAvailable, !hintDropped, !isHuntPaused else { return }
        hintDropped = true
        if mode == .scatter { ar.pointsToNearestHidden = true }
    }

    /// The seeker gives up: the round ends there, the hider wins, and it lights up.
    func giveUp() {
        guard phase == .seeking, countdown == nil else { return }
        stopClock()
        isHuntPaused = false
        pausedRemaining = nil
        Sound.shared.play(.lose)
        ar.setMode(.showing)
        if mode == .scatter { ar.scatter.revealUnfound() } else { ar.revealCharacter() }
        phase = .hiderWon
    }

    private func seekerFoundOne(_ actor: ChameleonActor) {
        guard phase == .seeking, !isHuntPaused, mode == .scatter else { return }
        let elapsed = TimeInterval(roundDuration) - (deadline.map { max(0, $0.timeIntervalSinceNow) } ?? 0)
        ar.scatter.markFound(actor, after: elapsed)
        foundCount = ar.scatter.foundCount
        Sound.shared.play(.found)
        pay(CoinRules.find(base: CoinRules.findBase(swarmDifficulty), elapsed: elapsed, of: TimeInterval(roundDuration),
                           hintOn: hintDropped))
        if ar.scatter.remaining == 0 {
            stopClock()
            playWin()
            ar.setMode(.showing)
            phase = .seekerWon
        }
    }

    /// Coins for a find: into the wallet, and onto this hunt's count.
    private func pay(_ coins: Int) {
        coinsThisRound += coins
        Wallet.shared.earn(coins)
    }

    private func seekerFound() {
        guard phase == .seeking, !isHuntPaused else { return }
        let elapsed = TimeInterval(roundDuration) - (deadline.map { max(0, $0.timeIntervalSinceNow) } ?? 0)
        pay(CoinRules.find(base: CoinRules.paintAndHideBase, elapsed: elapsed, of: TimeInterval(roundDuration), hintOn: hintDropped))
        stopClock()
        Sound.shared.play(.found)
        playWin()
        ar.setMode(.showing)
        ar.revealCharacter()
        phase = .seekerWon
    }

    private func seekerMissed() {
        guard phase == .seeking else { return }
        missCount += 1
        Sound.shared.play(.miss)
        // Swarm from Medium on: a tap on nothing costs time, so tapping all over the
        // screen isn't a way to find them.
        let penalty = mode == .scatter ? swarmDifficulty.missPenalty : 0
        guard penalty > 0, countdown == nil, !isHuntPaused, let deadline else { return }
        self.deadline = deadline.addingTimeInterval(-TimeInterval(penalty))
        penaltiesTaken += 1
        tick()
    }

    /// The fanfare, just after the FOUND chime.
    private func playWin() {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            Sound.shared.play(.win)
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
        countdown = nil
        deadline = nil
    }

    // MARK: - Squad

    func openSquad() {
        guard ARSessionController.isARAvailable else {
            notice = .needsAR
            return
        }
        stopClock()
        studio = nil
        ar.reset()
        phase = .squad
    }

    func leaveSquad() {
        squad.leave()
        phase = .intro
    }

    // MARK: - Reset

    func exitToIntro() {
        stopClock()
        foundCount = 0
        isHuntPaused = false
        pausedRemaining = nil
        studio = nil
        ar.reset()
        phase = .intro
    }

    // MARK: - Debug launch arguments

    #if DEBUG
    /// For automated checks in the Simulator:
    ///   -demoStudio floor|wall  -demoPose <pose>  -demoAutoCamo  -demoStroke  -demoCamoStroke
    ///   -demoCamera <azimuth> <elevation> <distance>  -demoShading  -demoHideScan
    ///   -debugPhase arCheckLocating|arCheckLost|arCheckVisible|handoff|seeking|paused|result
    func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String, offset: Int = 1) -> String? {
            guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
            return args[i + offset]
        }

        // `-debugNotice tooFast|spotMoved|…|surface` shows the scan's message over the scan.
        if let problem = value(after: "-debugNotice") {
            ar.debugScanProgress(0.3)
            phase = .scanning
            notice = problem == "surface"
                ? Notice(title: "Can't see the surface", message: "Hide it on something solid that stays still, then walk round it.",
                         systemImage: "square.3.layers.3d.down.right.slash",
                         primary: .init(title: "Move it", systemImage: "hand.point.up.left.fill"),
                         secondary: .init(title: "Scan again"))
                : scanTrouble(KeyframeCollector.Problem(rawValue: problem))
            return
        }

        // `-debugDifficulty easy|medium|hard`: Swarm's difficulty for the screens below.
        if let difficulty = value(after: "-debugDifficulty").flatMap(HuntDifficulty.init(rawValue:)) {
            swarmDifficulty = difficulty
        }

        if let squadPhase = value(after: "-debugSquad") {
            // home | rooms | lobby | lobbyGuest | syncing | hiding | lookAway | waiting | hunting | huntIntro [secs] | results | resultsHost
            phase = .squad
            switch squadPhase {
            case "home": break
            case "rooms": squad.link.debugRooms()
            case "lobby": squad.debugFill(phase: .lobby, host: true)
            case "lobbyHard": squad.debugFill(phase: .lobby, host: true); squad.debugDifficulty(.hard)
            case "lobbyGuestHard": squad.debugFill(phase: .lobby, host: false, mode: .hiderVsAll); squad.debugDifficulty(.hard)
            case "lobbyGuest": squad.debugFill(phase: .lobby, host: false, mode: .hiderVsAll)
            case "lobbyMixed": squad.debugFill(phase: .lobby, host: true, lidar: [true, false, false, true])
            case "lobbyLite": squad.debugFill(phase: .lobby, host: true, lidar: [false, false, false, false])
            case "syncing": squad.debugFill(phase: .syncing, host: true)
            case "hiding": squad.debugFill(phase: .hiding, host: true)
            case "lookAway": squad.debugFill(phase: .hiding, host: false, mode: .hiderVsAll)
            case "waiting": squad.debugFill(phase: .hiding, host: true, doneHiding: true)
            case "hunting": squad.debugFill(phase: .hunting, host: true)
            case "huntingHint": squad.debugFill(phase: .hunting, host: true); squad.debugHintOn()
            case "hidingAuto": squad.debugFill(phase: .hiding, host: true); squad.debugAutoPlacing()
            case "huntingMissed": squad.debugFill(phase: .hunting, host: true); squad.debugMissed()
            case "huntingGaveUp":
                squad.debugFill(phase: .hunting, host: true); squad.debugGiveUp()
                Task { @MainActor [ar] in
                    try? await Task.sleep(for: .seconds(1.5))
                    ar.tags.debugSample(in: ar.arView.bounds.size)
                }
            case "huntIntro": squad.debugHuntIntro(seconds: Double(value(after: "-debugSquad", offset: 2) ?? "") ?? 30)
            case "results": squad.debugFill(phase: .results, host: false)
            case "resultsHost": squad.debugFill(phase: .results, host: true)
            // Real networking between two Simulators: one hosts, the other joins the first
            // room it sees. `-debugAutoStart` has the host start once someone's in.
            case "autoHost":
                if let name = value(after: "-debugName") { playerName = name }
                squad.host()
                // `-debugAutoPlay <hide> <finds>`: play a round with no camera (SquadGame.debugAutoPlay).
                if let hide = value(after: "-debugAutoPlay").flatMap(Int.init) {
                    var settings = SquadSettings()
                    settings.perPlayer = 4; settings.hideSeconds = 20; settings.huntSeconds = 60
                    if let level = value(after: "-debugDifficulty").flatMap(HuntDifficulty.init(rawValue:)) { settings.difficulty = level }
                    squad.debugAutoPlay(hide: hide, finds: Int(value(after: "-debugAutoPlay", offset: 2) ?? "") ?? 0,
                                        settings: settings)
                }
                if args.contains("-debugAutoStart") {
                    Task { @MainActor in
                        for _ in 0..<120 {
                            try? await Task.sleep(for: .seconds(0.5))
                            if squad.state.players.count >= 2 { squad.startSync(); break }
                        }
                    }
                }
            case "autoJoin":
                if let name = value(after: "-debugName") { playerName = name }
                squad.browse()
                if let hide = value(after: "-debugAutoPlay").flatMap(Int.init) {
                    squad.debugLoseNextClaim = args.contains("-debugLoseClaim")
                    squad.debugAutoPlay(hide: hide, finds: Int(value(after: "-debugAutoPlay", offset: 2) ?? "") ?? 0)
                }
                Task { @MainActor in
                    for _ in 0..<120 {
                        try? await Task.sleep(for: .seconds(0.5))
                        if let room = squad.link.rooms.first { squad.join(room); break }
                    }
                }
            default: break
            }
            return
        }

        if let debugPhase = value(after: "-debugPhase") {
            if roundNumber == 0 { roundNumber = 42 }
            switch debugPhase {
            case "arCheckLocating": ar.debugSetCharacterStatus(.locating); phase = .arCheck
            case "arCheckLost": ar.debugSetCharacterStatus(.locating, locatingFor: 30); phase = .arCheck
            case "arCheckVisible":
                ar.debugSetCharacterStatus(.visible)
                ar.showDiagnostics = args.contains("-debugDiagnostics")
                phase = .arCheck
            case "handoff": phase = .handoff
            case "scatter":
                mode = .scatter
                ar.scatter.debugFill(count: 4, found: 0)
                phase = .scattering
            case "scatterHandoff":
                mode = .scatter
                ar.scatter.debugFill(count: 6, found: 0)
                secondsRemaining = roundDuration
                phase = .handoff
            case "scatterSeeking":
                mode = .scatter
                ar.scatter.debugFill(count: 6, found: 2)
                foundCount = 2
                coinsThisRound = 64
                hintAvailable = hintsOn
                phase = .seeking
                startClock(seconds: TimeInterval(roundDuration))
            case "scatterHinted":
                // The hint switched on: the arrow's out and finds pay half.
                mode = .scatter
                ar.scatter.debugFill(count: 6, found: 2)
                foundCount = 2
                coinsThisRound = 64
                hintAvailable = true
                hintDropped = true
                phase = .seeking
                startClock(seconds: TimeInterval(roundDuration))
            case "scatterPenalty":
                // A miss on Hard, a moment in: the "-5 s" by the clock.
                mode = .scatter
                swarmDifficulty = .hard
                ar.scatter.debugFill(count: 6, found: 2)
                foundCount = 2
                phase = .seeking
                startClock(seconds: TimeInterval(roundDuration))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.seekerMissed()
                }
            case "scatterResult":
                mode = .scatter
                ar.scatter.debugFill(count: 6, found: 4)
                foundCount = 4; missCount = 3; secondsRemaining = 0
                coinsThisRound = 132
                phase = .hiderWon
            case "scanning": ar.debugScanProgress(0.42); phase = .scanning
            case "scanStuck": ar.debugScanProgress(0.2, stalled: true); phase = .scanning
            case "processing":
                processingMessage = "Remembering the colours…"; processingProgress = 0.45; phase = .processing
            case "countdown":
                phase = .seeking; countdown = 2
            case "clue":
                phase = .seeking
                startClock(seconds: 58)
                hintAvailable = true
                hintDropped = true
            case "hintReady":
                phase = .seeking
                startClock(seconds: 58)
                hintAvailable = true
            case "seeking":
                phase = .seeking
                hintAvailable = hintsOn
                startClock(seconds: TimeInterval(huntDuration))
            case "paused":
                phase = .seeking
                startClock(seconds: TimeInterval(huntDuration))
                missCount = 2
                pauseHunt()
            case "result": missCount = 3; secondsRemaining = 41; coinsThisRound = 31; phase = .seekerWon
            case "timeup": missCount = 5; secondsRemaining = 0; phase = .hiderWon
            case "placing": ar.setMode(.placing); phase = .placing
            case "replacing": ar.debugSetCharacterStatus(.replacing); phase = .arCheck
            default: break
            }
            return
        }

        guard let surfaceName = value(after: "-demoStudio") else { return }
        let surface: SurfaceKind = surfaceName == "wall" ? .wall : .floor
        let pose = value(after: "-demoPose").flatMap(CharacterPose.init(rawValue:))
        openDemo(surface: surface, pose: pose)

        Task {
            while studio == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(800))
            guard let studio else { return }
            if let az = value(after: "-demoCamera").flatMap(Float.init),
               let el = value(after: "-demoCamera", offset: 2).flatMap(Float.init),
               let dist = value(after: "-demoCamera", offset: 3).flatMap(Float.init) {
                studio.debugSetCamera(azimuthDegrees: az, elevationDegrees: el, distance: dist)
            }
            if args.contains("-demoShading") { studio.shapeShading = true }
            if args.contains("-demoHideScan") { studio.showEnvironment = false }
            if args.contains("-demoAutoCamo") { studio.autoCamouflage() }
            let size = studio.arView.bounds.size
            if args.contains("-demoStroke") {
                studio.color = [0.85, 0.1, 0.2]
                studio.brushSizeCentimeters = 2
                studio.debugStroke(from: CGPoint(x: size.width * 0.45, y: size.height * 0.40),
                                   to: CGPoint(x: size.width * 0.55, y: size.height * 0.60))
            }
            if args.contains("-demoCamoStroke") {
                studio.tool = .camo
                studio.brushSizeCentimeters = 3
                for row in stride(from: 0.30, through: 0.75, by: 0.03) {
                    studio.debugStroke(from: CGPoint(x: size.width * 0.40, y: size.height * row),
                                       to: CGPoint(x: size.width * 0.60, y: size.height * row))
                }
            }
        }
    }
    #endif
}
