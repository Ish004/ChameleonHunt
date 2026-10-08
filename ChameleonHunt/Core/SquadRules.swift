//
//  SquadRules.swift
//  The multiplayer game as plain data: who's in, what phase it is, who hid which
//  chameleon, who found it — and the rules for changing any of that.
//
//  Squad play is several phones or iPads in the same room on the same Wi-Fi, each
//  player hiding and hunting on their own device. One device hosts. Every change goes to
//  the host as an intent ("I placed one", "I found that one"); the host applies it with
//  these rules and sends everyone the new state. So there's exactly one answer to "who
//  tapped it first", and a device that drops out and back in just gets the latest state.
//
//  Not every phone has LiDAR, the depth sensor that maps the room and lets real things hide
//  a chameleon. How much of the room the game knows depends on who's playing (roomSupport):
//   - Everyone has LiDAR: the full game, every device seeing through its own sensor.
//   - Someone does: that device (the host, if it can) maps the room and shares the map, so
//     the others can hide on any surface and still have furniture hide chameleons.
//   - Nobody does: the lite game — chameleons on flat surfaces, and only people hide them.
//
//  Two modes, both built on the lots-of-chameleons game:
//   - Free-for-all: everyone hides a few, then everyone hunts everyone else's. A find
//     scores the finder; a chameleon nobody finds scores whoever hid it.
//   - Hider vs all: one player hides a swarm; everyone else races to find them.
//     The hider scores for every one that survives. The hider rotates each round.
//
//  Plain Swift, so it's tested in Tools/coretest.
//

import Foundation

enum SquadMode: String, Codable, Sendable, CaseIterable {
    case freeForAll
    case hiderVsAll
}

struct SquadPlayer: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    /// Index into the squad colours.
    var colour: Int
    /// Their AR session's identifier, so other devices can tell when they've met in AR.
    var arSession: UUID?
    /// Whether their device has a LiDAR scanner.
    var lidar = false

    init(id: UUID, name: String, colour: Int, arSession: UUID?, lidar: Bool = false) {
        self.id = id
        self.name = name
        self.colour = colour
        self.arSession = arSession
        self.lidar = lidar
    }
}

/// How much of the room the squad's devices know (see the top of the file).
enum RoomSupport: Equatable, Sendable {
    case full
    case shared(scanner: UUID)
    case flat
}

struct SquadSettings: Codable, Equatable, Sendable {
    var mode: SquadMode = .freeForAll
    /// Free-for-all: how many each player hides. Hider vs all: how many the hider hides.
    var perPlayer = 3
    var swarm = 8
    var hideSeconds = 120
    var huntSeconds = 180
    /// A Hint key unlocks halfway through the hunt; each player chooses whether to use it.
    var hints = true
    /// How well hidden the chameleons are and what a miss costs: the same levels, doing
    /// the same things, as Swarm's (HuntDifficulty).
    var difficulty: HuntDifficulty = .easy

    var hiding: Int { mode == .freeForAll ? perPlayer : swarm }

    /// The host's choices. Longer since v6.9: playtesters ran out of time at the old
    /// longest (2 minutes to hide, 5 to hunt) in a real house. A hide time of 0 is no
    /// limit: the hunt starts when everyone has hidden theirs.
    static let hideChoices = [60, 120, 180, 300, 0]
    static let huntChoices = [120, 180, 300, 480, 600]

    /// Whether hiding is against the clock.
    var hidingIsTimed: Bool { hideSeconds > 0 }

    /// After the hide clock runs out, how long anyone still short of their chameleons is
    /// given to have the rest placed for them (SquadGame.autoPlace), in seconds: a few for
    /// each, since each one blends in before the next is dropped.
    var autoPlaceAllowance: Int { hiding * 4 + 6 }
}

enum SquadPhase: String, Codable, Sendable {
    /// Players joining; host picks the mode.
    case lobby
    /// Everyone pointing at the same bit of room until their AR sessions have met.
    case syncing
    case hiding
    case hunting
    case results
}

struct SquadChameleon: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var owner: UUID
    var pose: String
    var scale: Float
    var foundBy: UUID?
    /// Where it is, relative to the host's reference point in the room (a shared ARKit
    /// anchor every device has once it has synced with the host): a 4×4 transform,
    /// column by column. With this, a device only has to sync with the host — not with
    /// every other player — to see everyone's chameleons in the right place.
    var spot: [Float]? = nil
}

struct SquadState: Codable, Equatable, Sendable {
    var players: [SquadPlayer] = []
    var settings = SquadSettings()
    var phase: SquadPhase = .lobby
    /// Bumped whenever a timed phase starts, so every device restarts its clock.
    var phaseNumber = 0
    /// Seconds the current timed phase lasts, from when it was announced.
    var phaseSeconds = 0
    var round = 0
    var hider: UUID?
    var synced: Set<UUID> = []
    var doneHiding: Set<UUID> = []
    var chameleons: [SquadChameleon] = []
    /// Bumped by the host with every change, so a device never goes back to an older state.
    var version = 0
    /// When the current timed phase started, on the host's clock. Each device converts it
    /// to its own clock (SquadGame), so every clock shows the same time however late the
    /// message arrived.
    var phaseStartedAt: Date?
    /// Players whose device has dropped off mid-game. Their place (and their chameleons)
    /// is kept for a while in case they come straight back — phones lose Wi-Fi for a
    /// moment, or get locked — and the host removes them if they don't.
    var away: Set<UUID> = []
    /// Seekers who gave up this hunt: they can't find any more, and see where the rest are.
    var gaveUp: Set<UUID> = []

    static let maximumPlayers = 6
}

/// Something a player wants to happen. Only the host applies these.
enum SquadIntent: Codable, Sendable {
    case join(SquadPlayer)
    case leave(UUID)
    /// Their device dropped off mid-game (see SquadState.away); a join brings them back.
    case away(UUID)
    case settings(SquadSettings)
    case startSync
    case synced(UUID)
    case startHiding
    case placed(SquadChameleon)
    case removed(UUID)
    case doneHiding(UUID)
    case startHunt
    case claim(chameleon: UUID, by: UUID)
    /// A seeker stops hunting (they couldn't find the rest).
    case giveUp(UUID)
    case endRound
    case backToLobby
}

enum SquadRules {

    /// Applies an intent. Returns false if it was refused or changed nothing.
    @discardableResult
    static func apply(_ intent: SquadIntent, to state: inout SquadState) -> Bool {
        switch intent {
        case .join(var player):
            if let index = state.players.firstIndex(where: { $0.id == player.id }) {
                // Rejoining (or a new AR session): keep their colour.
                player.colour = state.players[index].colour
                let wasAway = state.away.remove(player.id) != nil
                guard state.players[index] != player else { return wasAway }
                state.players[index] = player
                return true
            }
            guard state.players.count < SquadState.maximumPlayers, state.phase == .lobby else { return false }
            let used = Set(state.players.map(\.colour))
            player.colour = (0..<SquadState.maximumPlayers).first { !used.contains($0) } ?? 0
            state.players.append(player)
            return true

        case .leave(let id):
            guard state.players.contains(where: { $0.id == id }) else { return false }
            state.players.removeAll { $0.id == id }
            state.synced.remove(id)
            state.doneHiding.remove(id)
            state.away.remove(id)
            // Their chameleons go with them.
            state.chameleons.removeAll { $0.owner == id }
            if state.hider == id { state.hider = nil }
            return true

        case .away(let id):
            guard state.phase != .lobby, state.players.contains(where: { $0.id == id }),
                  !state.away.contains(id) else { return false }
            state.away.insert(id)
            return true

        case .settings(let settings):
            guard state.phase == .lobby || state.phase == .results, settings != state.settings else { return false }
            state.settings = clamped(settings)
            return true

        case .startSync:
            guard state.phase == .lobby || state.phase == .results, state.players.count >= 2 else { return false }
            state.phase = .syncing
            state.synced = []
            state.doneHiding = []
            state.gaveUp = []
            state.chameleons = []
            state.round += 1
            if state.settings.mode == .hiderVsAll {
                // Take turns: the next player after last round's hider.
                let ids = state.players.map(\.id)
                let last = state.hider.flatMap { ids.firstIndex(of: $0) } ?? -1
                state.hider = ids[(last + 1) % ids.count]
            } else {
                state.hider = nil
            }
            return true

        case .synced(let id):
            guard state.phase == .syncing, state.players.contains(where: { $0.id == id }),
                  !state.synced.contains(id) else { return false }
            state.synced.insert(id)
            return true

        case .startHiding:
            guard state.phase == .syncing, everyoneSynced(state) else { return false }
            state.phase = .hiding
            state.phaseNumber += 1
            state.phaseSeconds = state.settings.hideSeconds
            // In hider-vs-all, nobody but the hider has anything to hide.
            state.doneHiding = Set(state.players.map(\.id).filter { !canHide($0, in: state) })
            return true

        case .placed(let chameleon):
            guard state.phase == .hiding, canHide(chameleon.owner, in: state),
                  !state.doneHiding.contains(chameleon.owner),
                  !state.chameleons.contains(where: { $0.id == chameleon.id }),
                  hiddenCount(by: chameleon.owner, in: state) < state.settings.hiding else { return false }
            var placed = chameleon
            placed.foundBy = nil
            state.chameleons.append(placed)
            return true

        case .removed(let id):
            guard state.phase == .hiding, state.chameleons.contains(where: { $0.id == id }) else { return false }
            state.chameleons.removeAll { $0.id == id }
            return true

        case .doneHiding(let id):
            guard state.phase == .hiding, !state.doneHiding.contains(id),
                  state.players.contains(where: { $0.id == id }) else { return false }
            state.doneHiding.insert(id)
            return true

        case .startHunt:
            guard state.phase == .hiding, !state.chameleons.isEmpty else { return false }
            state.phase = .hunting
            state.phaseNumber += 1
            state.phaseSeconds = state.settings.huntSeconds
            return true

        case .claim(let chameleonID, let finder):
            guard state.phase == .hunting,
                  let index = state.chameleons.firstIndex(where: { $0.id == chameleonID }),
                  state.chameleons[index].foundBy == nil,
                  state.chameleons[index].owner != finder,
                  canSeek(finder, in: state) else { return false }
            state.chameleons[index].foundBy = finder
            return true

        case .giveUp(let id):
            guard state.phase == .hunting, canSeek(id, in: state) else { return false }
            state.gaveUp.insert(id)
            return true

        case .endRound:
            guard state.phase == .hunting else { return false }
            state.phase = .results
            return true

        case .backToLobby:
            guard state.phase != .lobby else { return false }
            state.phase = .lobby
            state.synced = []
            state.doneHiding = []
            state.gaveUp = []
            state.chameleons = []
            // Anyone still away by now isn't coming back.
            state.players.removeAll { state.away.contains($0.id) }
            state.away = []
            return true
        }
    }

    static func roomSupport(_ state: SquadState) -> RoomSupport {
        guard !state.players.isEmpty else { return .flat }
        if state.players.allSatisfy(\.lidar) { return .full }
        // The host maps the room if it can: everything goes through it anyway.
        if let host = state.players.first, host.lidar { return .shared(scanner: host.id) }
        if let scanner = state.players.first(where: \.lidar) { return .shared(scanner: scanner.id) }
        return .flat
    }

    static func everyoneSynced(_ state: SquadState) -> Bool {
        state.players.count >= 2 && state.players.allSatisfy { state.synced.contains($0.id) }
    }

    static func everyoneDoneHiding(_ state: SquadState) -> Bool {
        state.players.allSatisfy { state.doneHiding.contains($0.id) }
    }

    static func canHide(_ player: UUID, in state: SquadState) -> Bool {
        state.settings.mode == .freeForAll || state.hider == player
    }

    /// Whether this player is hunting: not the hider in hider-vs-all, and hasn't given up.
    static func canSeek(_ player: UUID, in state: SquadState) -> Bool {
        (state.settings.mode == .freeForAll || state.hider != player) && !state.gaveUp.contains(player)
    }

    /// Every seeker has given up (or there's nobody left hunting): the hunt can end.
    static func everyoneGaveUp(_ state: SquadState) -> Bool {
        state.phase == .hunting && !state.players.contains { canSeek($0.id, in: state) }
    }

    static func hiddenCount(by player: UUID, in state: SquadState) -> Int {
        state.chameleons.filter { $0.owner == player }.count
    }

    /// True once every chameleon has been found — the hunt can end early.
    static func allFound(_ state: SquadState) -> Bool {
        !state.chameleons.isEmpty && state.chameleons.allSatisfy { $0.foundBy != nil }
    }

    /// Anything this player could still find.
    static func findable(for player: UUID, in state: SquadState) -> [SquadChameleon] {
        state.chameleons.filter { $0.foundBy == nil && $0.owner != player }
    }

    struct Score: Equatable, Sendable {
        let player: SquadPlayer
        let finds: Int
        let survivors: Int
        var points: Int { finds + survivors }
    }

    /// The leaderboard: a point per find, a point per chameleon of yours nobody found.
    static func scores(_ state: SquadState) -> [Score] {
        state.players.map { player in
            Score(player: player,
                  finds: state.chameleons.filter { $0.foundBy == player.id }.count,
                  survivors: state.chameleons.filter { $0.owner == player.id && $0.foundBy == nil }.count)
        }
        .sorted { ($0.points, $0.finds) > ($1.points, $1.finds) }
    }

    private static func clamped(_ settings: SquadSettings) -> SquadSettings {
        var s = settings
        s.perPlayer = min(max(s.perPlayer, 1), 5)
        s.swarm = min(max(s.swarm, 3), 10)
        s.hideSeconds = s.hideSeconds == 0 ? 0 : min(max(s.hideSeconds, 20), 600)
        s.huntSeconds = min(max(s.huntSeconds, 30), 900)
        return s
    }
}

/// What travels between devices as messages. (Anything big — camouflage, the room map —
/// goes as a file transfer instead; see PeerLink.)
enum SquadMessage: Codable, Sendable {
    /// Guest → host.
    case intent(SquadIntent)
    /// Host → everyone: the whole game, after every change and every few seconds.
    case state(SquadState)
    /// Guest → host and back: how far apart their clocks are.
    case ping(sent: Date)
    case pong(sent: Date, host: Date)
    /// Host → everyone: leaving on purpose, so don't wait for it to come back.
    case bye
}
