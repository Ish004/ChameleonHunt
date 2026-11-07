//
//  SquadGame.swift
//  Runs a squad game on one device: the lobby, the host's clock, and the traffic
//  between the rules (SquadRules), the other devices (PeerLink) and the room (AR).
//
//  Every device holds the same SquadState. Players' actions become intents; guests send
//  theirs to the host, the host applies them and sends everyone the result. When the
//  state changes, each device brings its own AR view in line: starts the shared session
//  when syncing starts, lets the hiders drop chameleons, shows everyone's when the hunt
//  starts, marks the found ones. The host also keeps time and moves the game on — to the
//  hunt when everyone's hidden theirs (or time's up), to the results when they've all
//  been found (or time's up).
//
//  When only some devices have LiDAR, one of them maps the room while everyone hides and
//  hunts, and sends the map round every few seconds (SquadRules.roomSupport, RoomShare).
//

import Combine
import Foundation
import MultipeerConnectivity
import SwiftUI
import UIKit

@MainActor
final class SquadGame: ObservableObject {

    @Published private(set) var state = SquadState()
    @Published private(set) var roomCode = ""
    /// When the current timed phase ends, on this device's clock.
    @Published private(set) var deadline: Date?
    /// The latest thing that happened, for the hunt's feed ("ANA FOUND ONE OF BEN'S").
    @Published private(set) var lastEvent: String?
    /// Who the latest thing was done by, for the feed's colour.
    @Published private(set) var lastEventBy: SquadPlayer?
    /// When the hunt proper starts on this device's clock: after the intro card (who to
    /// find, then 3-2-1), which every device shows at the same moment. The clock and
    /// the taps start here.
    @Published private(set) var huntStartsAt: Date?
    /// This player used the hint this hunt.
    @Published private(set) var hintUsed = false
    /// Coins this player has earned this round: for finds as the host confirms them, and
    /// at the end for each of theirs nobody found and for coming top (Core/Coins.swift).
    /// They go into the wallet as they're earned.
    @Published private(set) var coinsFromFinds = 0
    @Published private(set) var coinsForUnfound = 0
    @Published private(set) var coinsForWinning = 0
    var coinsThisRound: Int { coinsFromFinds + coinsForUnfound + coinsForWinning }
    /// The hide clock ran out with some of this player's still to place: they're being
    /// dropped for them, one at a time, wherever the camera points.
    @Published private(set) var autoPlacing = false
    private var autoPlaceTask: Task<Void, Never>?

    /// Medium and Hard: this player tapped nothing, and can't tap again until then. (In
    /// Swarm a miss comes off the seeker's clock; here everyone shares the clock, so it
    /// costs the one who missed the same seconds of hunting.)
    @Published private(set) var missLockedUntil: Date?

    /// How long the hunt's intro lasts, in seconds; the hunt's clock runs after it.
    static let huntLeadIn: TimeInterval = 4
    /// The host went away mid-game.
    @Published private(set) var hostLost = false
    /// Guest: the connection to the host dropped mid-game and we're getting back in.
    @Published private(set) var reconnecting = false
    @Published private(set) var me: SquadPlayer
    /// Chameleons this device has claimed — counted the moment they're tapped, so the
    /// FOUND shows at once rather than when the host's answer comes back.
    @Published private(set) var claimsMade = 0
    /// Whether to see your own chameleons during the hunt. Off by default: players who
    /// could see theirs kept mistaking them for finds. Kept between games.
    @Published private(set) var showMine = UserDefaults.standard.bool(forKey: "squadShowMine")

    let link: PeerLink
    private let ar: ARSessionController
    private var peerPlayers: [MCPeerID: UUID] = [:]
    private var hostTimer: Task<Void, Never>?
    /// Sending the room map round, on the device that makes it.
    private var mappingTask: Task<Void, Never>?
    private var lastMapTriangles = 0
    private var skinsSent: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []
    /// The host re-sends the whole game every few seconds, so a device that missed or
    /// got something late catches up by itself.
    private var heartbeat: Task<Void, Never>?
    /// Guests: how far ahead the host's clock is (seconds), from the quickest ping.
    private var clockOffset: TimeInterval = 0
    private var quickestPing: TimeInterval = .infinity
    private var pinging: Task<Void, Never>?
    /// Finishing by itself a moment after the last one is placed (Undo stops it).
    private var autoFinish: Task<Void, Never>?
    /// Guest: finding the host again after dropping off.
    private var reconnectTask: Task<Void, Never>?
    /// Finds tapped here that the host hasn't answered yet, and the one sending them
    /// again until it does. A claim sent once could be lost when the connection blinked,
    /// and nothing noticed: in testing a guest's finds showed FOUND on their phone, never
    /// reached the host, and the scoreboard gave them nothing.
    private var pendingClaims: Set<UUID> = []
    private var claimResender: Task<Void, Never>?
    /// Host: players who dropped off mid-game, removed if they're not back in time.
    private var awayTimers: [UUID: Task<Void, Never>] = [:]
    /// How long a player who drops off mid-game keeps their place.
    static let awayGrace: TimeInterval = 30
    /// How long a guest keeps trying to get back to the host.
    static let reconnectWindow: TimeInterval = 25
    /// How long after time's up the host still takes finds that were on their way.
    static let claimGrace: TimeInterval = 1.5

    var isHost: Bool { link.role == .host }
    var inRoom: Bool {
        #if DEBUG
        if debugInRoom { return true }
        #endif
        return isHost || link.hostPeer != nil || reconnecting
    }
    #if DEBUG
    private var debugInRoom = false
    #endif

    init(ar: ARSessionController, name: String) {
        self.ar = ar
        me = SquadPlayer(id: UUID(), name: name, colour: 0, arSession: nil, lidar: ARSessionController.isLiDARAvailable)
        link = PeerLink(name: name)
        link.onMessage = { [weak self] message, peer in self?.received(message, from: peer) }
        link.onCollaboration = { [weak self] data in self?.ar.receiveCollaboration(data) }
        link.onResource = { [weak self] name, data in self?.receivedResource(name, data) }
        link.onConnected = { [weak self] peer in self?.connected(peer) }
        link.onDisconnected = { [weak self] peer in self?.disconnected(peer) }
        link.isReturning = { [weak self] id in self?.state.players.contains { $0.id == id } ?? false }
        ar.onSquadClaim = { [weak self] id in self?.claim(id) }
        ar.onSquadMiss = { [weak self] in self?.missed() }
        // Forward the link's changes, so views watching the game see rooms and peers.
        link.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        ar.$squadOrigin.sink { [weak self] _ in
            Task { @MainActor in self?.checkSynced() }
        }.store(in: &cancellables)
        ar.$sessionID.removeDuplicates().sink { [weak self] id in
            Task { @MainActor in self?.sessionChanged(id) }
        }.store(in: &cancellables)
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !inRoom else { return }
        me.name = String(trimmed.prefix(16))
        link.rename(me.name)
    }

    // MARK: - Rooms

    func host() {
        leave()
        roomCode = String((0..<4).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ".randomElement()! })
        me.arSession = ar.localSessionID
        state = SquadState()
        link.host(code: roomCode, name: me.name)
        SquadRules.apply(.join(me), to: &state)
        me = state.players.first { $0.id == me.id } ?? me
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.isHost else { return }
                if self.state.phase != .lobby { self.link.send(.state(self.state)) }
            }
        }
    }

    func browse() {
        leave()
        link.browse()
    }

    func join(_ room: PeerLink.Room) {
        roomCode = room.code
        link.join(room, as: me.id)
    }

    /// Back from the background. A host's room may have stopped being advertised.
    func appBecameActive() {
        if isHost { link.resumeAdvertising() }
    }

    func leave() {
        hostTimer?.cancel()
        hostTimer = nil
        heartbeat?.cancel()
        heartbeat = nil
        pinging?.cancel()
        pinging = nil
        clockOffset = 0
        quickestPing = .infinity
        claimsMade = 0
        pendingClaims = []
        claimResender?.cancel()
        claimResender = nil
        autoFinish?.cancel()
        autoFinish = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        for timer in awayTimers.values { timer.cancel() }
        awayTimers = [:]
        huntStartsAt = nil
        lastEventBy = nil
        missLockedUntil = nil
        autoPlaceTask?.cancel()
        autoPlaceTask = nil
        autoPlacing = false
        stopMapping()
        if isHost, state.players.count > 1 {
            // Tell everyone it's on purpose, so they don't wait for us to come back.
            link.send(.bye)
            link.stop(lingering: true)
        } else if link.role != nil {
            link.stop()
        }
        if ar.squadMode { ar.endSquadSession() }
        state = SquadState()
        peerPlayers = [:]
        skinsSent = []
        deadline = nil
        lastEvent = nil
        hostLost = false
        roomCode = ""
    }

    // MARK: - What players do

    func setSettings(_ settings: SquadSettings) { send(.settings(settings)) }
    func startSync() { send(.startSync) }
    func startHiding() { send(.startHiding) }
    func startHunt() { send(.startHunt) }
    func finishHiding() { send(.doneHiding(me.id)) }

    /// Stop hunting: can't find any more, and see where the rest are.
    func giveUp() {
        guard state.phase == .hunting, SquadRules.canSeek(me.id, in: state) else { return }
        ar.pointsToNearestHidden = false
        send(.giveUp(me.id))
    }

    /// The hint: an arrow to the nearest one still to find (not your own). Each player's
    /// choice, at any moment of the hunt; from then on their finds pay half the coins.
    func useHint() {
        guard state.phase == .hunting, state.settings.hints, SquadRules.canSeek(me.id, in: state), !hintUsed else { return }
        hintUsed = true
        ar.pointsToNearestHidden = true
    }

    /// See (or stop seeing) your own chameleons during the hunt.
    func setShowMine(_ show: Bool) {
        guard show != showMine else { return }
        showMine = show
        UserDefaults.standard.set(show, forKey: "squadShowMine")
        syncAR()
    }

    func playAgain() { send(.startSync) }
    func backToLobby() { send(.backToLobby) }

    func drop() {
        guard state.phase == .hiding, SquadRules.canHide(me.id, in: state), !state.doneHiding.contains(me.id),
              SquadRules.hiddenCount(by: me.id, in: state) < state.settings.hiding,
              let chameleon = ar.dropSquadChameleon() else { return }
        send(.placed(chameleon))
        Sound.shared.play(.drop)
        // The last one: after a moment to see it blend in (and to Undo), on to waiting
        // for the others by itself — there's nothing else to do.
        if placedHere >= state.settings.hiding {
            autoFinish?.cancel()
            autoFinish = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.state.phase == .hiding,
                      !self.state.doneHiding.contains(self.me.id),
                      self.placedHere >= self.state.settings.hiding else { return }
                self.finishHiding()
            }
        }
    }

    func undo() {
        guard state.phase == .hiding, let id = ar.undoSquadChameleon() else { return }
        autoFinish?.cancel()
        autoFinish = nil
        send(.removed(id))
    }

    /// Whether the next of mine can go down right now: there's somewhere to put it, and the
    /// last one has finished blending in.
    private var canDropNow: Bool {
        ar.probe?.isPlaceable == true && ar.scatter.geometriesReady && ar.scatter.previewReady
    }

    /// When the hide clock runs out with some of this player's chameleons still to place,
    /// the rest are placed for them: each wherever the camera is pointing as soon as it's
    /// somewhere one can go, the next once that one has blended in. Everyone ends up
    /// having hidden the same number, so nobody loses the points for ones they never got
    /// down (which happened: four hidden against three). The host waits for it
    /// (SquadSettings.autoPlaceAllowance) before starting the hunt.
    private func watchHideClock() {
        autoPlaceTask?.cancel()
        autoPlacing = false
        guard canHide, state.settings.hidingIsTimed else { return }
        autoPlaceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, self.state.phase == .hiding else { return }
                if self.state.doneHiding.contains(self.me.id) || self.placedHere >= self.state.settings.hiding {
                    // All down (the last one finishes by itself a moment after it lands).
                    if self.autoPlacing { self.autoPlacing = false }
                    continue
                }
                guard let deadline = self.deadline, Date() >= deadline else { continue }
                if !self.autoPlacing { self.autoPlacing = true }
                if self.canDropNow { self.drop() }
            }
        }
    }

    /// Mine in the room on this device (the state can be a moment behind on a guest).
    private var placedHere: Int { ar.scatter.records.filter { $0.hiddenBy.id == me.id }.count }

    /// Each player's name, for the tags over their finds.
    private var names: [UUID: String] {
        Dictionary(state.players.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Each player's colour, for their finds in the room.
    private var colours: [UUID: UIColor] {
        Dictionary(state.players.map { ($0.id, UIColor(Hunt.player($0.colour))) }, uniquingKeysWith: { a, _ in a })
    }

    /// The hunt has started properly (the intro is over) on this device's clock.
    var huntIsLive: Bool {
        state.phase == .hunting && (huntStartsAt.map { Date() >= $0 } ?? true)
    }

    var roomSupport: RoomSupport { SquadRules.roomSupport(state) }
    /// This device maps the room for the others.
    var isMapping: Bool { roomSupport == .shared(scanner: me.id) }

    var myHidden: Int { SquadRules.hiddenCount(by: me.id, in: state) }
    var myFinds: Int { state.chameleons.filter { $0.foundBy == me.id }.count }
    var canHide: Bool { SquadRules.canHide(me.id, in: state) }

    func player(_ id: UUID?) -> SquadPlayer? { state.players.first { $0.id == id } }
    /// Who everyone waits for, by name: the host joined first.
    var hostName: String { state.players.first?.name ?? "the host" }

    // MARK: - Messages

    private func send(_ intent: SquadIntent) {
        if isHost {
            applyAsHost(intent)
        } else {
            link.send(.intent(intent))
        }
    }

    private func applyAsHost(_ intent: SquadIntent) {
        var next = state
        guard SquadRules.apply(intent, to: &next) else { return }
        next.version = state.version + 1
        if next.phase != state.phase || next.phaseNumber != state.phaseNumber { next.phaseStartedAt = Date() }
        adopt(next)
        link.send(.state(next))
        hostAdvance()
    }

    /// A tap on someone else's chameleon: shown as found straight away, then sent to the
    /// host, which decides who got it first.
    private func claim(_ id: UUID) {
        guard huntIsLive, deadline.map({ Date() < $0 }) ?? true,
              isHost || link.hostPeer != nil, SquadRules.canSeek(me.id, in: state),
              let chameleon = state.chameleons.first(where: { $0.id == id }),
              chameleon.foundBy == nil, chameleon.owner != me.id, !pendingClaims.contains(id) else { return }
        ar.scatter.markFound(id, colour: UIColor(Hunt.player(me.colour)))
        Sound.shared.play(.found)
        claimsMade += 1
        #if DEBUG
        if debugLoseNextClaim, !isHost {
            // As if the connection blinked: this one never leaves the device.
            debugLoseNextClaim = false
            SquadLog.note("claim \(id.uuidString.prefix(6)) lost on the way")
            pendingClaims.insert(id)
            resendClaims()
            return
        }
        #endif
        send(.claim(chameleon: id, by: me.id))
        guard !isHost else { return }
        pendingClaims.insert(id)
        resendClaims()
    }

    /// A tap on nothing. Free on Easy; on Medium and Hard it costs this player a few
    /// seconds in which their taps don't count.
    private func missed() {
        let penalty = state.settings.difficulty.missPenalty
        guard huntIsLive, deadline.map({ Date() < $0 }) ?? true, SquadRules.canSeek(me.id, in: state) else { return }
        Sound.shared.play(.miss)
        guard penalty > 0 else { return }
        let until = Date().addingTimeInterval(TimeInterval(penalty))
        missLockedUntil = until
        ar.squadTapLock = until
    }

    /// Guest: sends the unanswered finds again every second until the host's game shows
    /// each one found (by us, or by someone quicker), or the hunt is over. The host takes
    /// a claim it already has as no change, so sending one twice is harmless.
    private func resendClaims() {
        guard claimResender == nil else { return }
        claimResender = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.pendingClaims.isEmpty, self.state.phase == .hunting else { break }
                guard self.link.hostPeer != nil else { continue }  // back when we're reconnected
                for id in self.pendingClaims {
                    #if DEBUG
                    SquadLog.note("resending claim \(id.uuidString.prefix(6))")
                    #endif
                    self.link.send(.intent(.claim(chameleon: id, by: self.me.id)))
                }
            }
            self?.claimResender = nil
        }
    }

    /// Answered claims: the host's game has the chameleon found, by anyone, or it's gone.
    private func settleClaims() {
        guard !pendingClaims.isEmpty else { return }
        if state.phase != .hunting {
            pendingClaims = []
            return
        }
        pendingClaims = pendingClaims.filter { id in
            state.chameleons.first(where: { $0.id == id }).map { $0.foundBy == nil } ?? false
        }
    }

    private func received(_ message: SquadMessage, from peer: MCPeerID) {
        switch message {
        case .intent(let intent):
            guard isHost else { return }
            if case .join(let player) = intent {
                peerPlayers[peer] = player.id
                awayTimers.removeValue(forKey: player.id)?.cancel()
            }
            applyAsHost(intent)
            // A newcomer needs the state even if their join changed nothing.
            link.send(.state(state), to: [peer])
        case .state(let next):
            // Never go back to an older state (the heartbeat can cross a newer change).
            guard !isHost, next.version >= state.version else { return }
            adopt(next)
        case .ping(let sent):
            guard isHost else { return }
            link.send(.pong(sent: sent, host: Date()), to: [peer])
        case .bye:
            guard !isHost, peer == link.hostPeer else { return }
            #if DEBUG
            SquadLog.note("host said bye")
            #endif
            reconnectTask?.cancel()
            reconnecting = false
            hostLost = true
        case .pong(let sent, let host):
            guard !isHost else { return }
            let now = Date()
            let roundTrip = now.timeIntervalSince(sent)
            // Trust the quickest round trip; let the record fade so it can adapt.
            quickestPing *= 1.2
            guard roundTrip < quickestPing else { return }
            quickestPing = roundTrip
            clockOffset = host.timeIntervalSince(sent) - roundTrip / 2
            updateDeadline()
        }
    }

    /// Camouflage and the room map arrive as file transfers.
    private func receivedResource(_ name: String, _ data: Data) {
        if name == "room" {
            ar.receiveRoom(data)
        } else if name.hasPrefix("skin:"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            ar.scatter.applySkin(id, jpeg: data)
        }
    }

    private func connected(_ peer: MCPeerID) {
        guard !isHost, peer == link.hostPeer else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        me.arSession = ar.localSessionID
        link.send(.intent(.join(me)))
        // Work out the host's clock: a few quick pings, then one now and then.
        pinging?.cancel()
        pinging = Task { [weak self] in
            var sent = 0
            while !Task.isCancelled {
                guard let self, self.inRoom else { return }
                self.link.send(.ping(sent: Date()))
                sent += 1
                try? await Task.sleep(for: .seconds(sent < 6 ? 1 : 10))
            }
        }
    }

    private func disconnected(_ peer: MCPeerID) {
        #if DEBUG
        SquadLog.note("disconnected \(peer.displayName) host=\(link.hostPeer?.displayName ?? "-") isHost=\(isHost) hostLost=\(hostLost)")
        #endif
        if isHost {
            guard let id = peerPlayers.removeValue(forKey: peer) else { return }
            guard state.phase != .lobby else {
                applyAsHost(.leave(id))
                return
            }
            // Mid-game, keep their place for a while: a phone that lost Wi-Fi for a moment,
            // or was locked, comes straight back (see reconnect) with its chameleons intact.
            applyAsHost(.away(id))
            awayTimers[id]?.cancel()
            awayTimers[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.awayGrace))
                guard !Task.isCancelled, let self, self.state.away.contains(id) else { return }
                self.awayTimers[id] = nil
                self.applyAsHost(.leave(id))
            }
        } else if peer == link.hostPeer, !hostLost {
            reconnect()
        }
    }

    /// Guest: the host dropped off. Look for the same room again and ask back in; if it
    /// doesn't turn up in time, the host has gone.
    private func reconnect() {
        #if DEBUG
        SquadLog.note("reconnecting to \(roomCode)")
        #endif
        reconnectTask?.cancel()
        reconnecting = true
        pinging?.cancel()
        let code = roomCode
        link.browse()
        reconnectTask = Task { [weak self] in
            let started = Date()
            var asked: MCPeerID?
            var failures = self?.link.joinFailures ?? 0
            while !Task.isCancelled, Date().timeIntervalSince(started) < Self.reconnectWindow {
                guard let self else { return }
                if self.link.hostPeer != nil { return }  // connected() takes it from here
                if self.link.joinFailures != failures {
                    failures = self.link.joinFailures
                    asked = nil  // turned away or timed out: ask again
                }
                if asked == nil, let room = self.link.rooms.first(where: { $0.code == code }) {
                    #if DEBUG
                    SquadLog.note("asking \(room.host) back in")
                    #endif
                    asked = room.peer
                    self.link.join(room, as: self.me.id)
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled, let self, self.link.hostPeer == nil else { return }
            #if DEBUG
            SquadLog.note("gave up reconnecting")
            #endif
            self.reconnecting = false
            self.hostLost = true
        }
    }

    // MARK: - Following the state

    private func adopt(_ next: SquadState) {
        let previous = state
        state = next
        if let updated = next.players.first(where: { $0.id == me.id }) { me = updated }

        updateDeadline()
        if next.phase != previous.phase || next.phaseNumber != previous.phaseNumber {
            enter(next.phase, from: previous.phase)
        }
        settleClaims()
        syncAR()
        for id in next.gaveUp.subtracting(previous.gaveUp) where id != me.id {
            lastEvent = "\((player(id)?.name ?? "?").uppercased()) GAVE UP"
            lastEventBy = player(id)
        }
        if next.phase == .lobby, previous.phase == .lobby, next.players.count > previous.players.count {
            Sound.shared.play(.join)
        }
        announceFinds(from: previous, to: next)
        // Someone's AR session ID may have changed; check again who we've met.
        if next.phase == .syncing { checkSynced() }
        if isHost { link.setAccepting(next.phase == .lobby) }
    }

    /// Brings this device's chameleons in line with the game.
    private func syncAR() {
        ar.syncSquad(chameleons: state.chameleons, phase: state.phase, colours: colours, names: names,
                     gaveUp: state.gaveUp.contains(me.id), showMine: showMine,
                     seeking: SquadRules.canSeek(me.id, in: state))
    }

    private func enter(_ phase: SquadPhase, from previous: SquadPhase) {
        switch phase {
        case .lobby:
            stopMapping()
            if ar.squadMode { ar.clearSquadRound() }
        case .syncing:
            if !ar.squadMode {
                ar.startSquadSession(me: me.id, isHost: isHost)
                ar.onCollaborationData = { [weak self] data, critical in
                    self?.link.sendCollaboration(data, reliable: critical)
                }
            } else {
                ar.clearSquadRound()
            }
            skinsSent = []
            checkSynced()
        case .hiding:
            ar.beginSquadHiding(canHide: canHide)
            if isMapping { startMapping() }
            watchHideClock()
        case .hunting:
            hintUsed = false
            coinsFromFinds = 0
            coinsForUnfound = 0
            coinsForWinning = 0
            autoPlaceTask?.cancel()
            autoPlacing = false
            missLockedUntil = nil
            ar.pointsToNearestHidden = false
            ar.beginSquadHunt(difficulty: state.settings.difficulty)
            sendSkins()
            // One last, fuller map of the room for the hunt.
            if isMapping { Task { await sendRoomMap(onlyIfGrown: true) } }
        case .results:
            deadline = nil
            // The round's other coins: for hiding well, and for coming top.
            let bonus = CoinRules.squadBonus(for: me.id, in: state)
            coinsForUnfound = bonus.unfound
            coinsForWinning = bonus.win
            Wallet.shared.earn(bonus.unfound + bonus.win)
            missLockedUntil = nil
            ar.squadTapLock = nil
            ar.pointsToNearestHidden = false
            stopMapping()
        }
    }

    /// When the current phase ends on this device's clock: the host's start time, moved
    /// onto this clock, plus the phase's length. Every device ends up showing the same
    /// time, however late the message arrived.
    private func updateDeadline() {
        guard state.phase == .hiding || state.phase == .hunting, state.phaseSeconds > 0 else {
            deadline = nil
            huntStartsAt = nil
            return
        }
        let started = state.phaseStartedAt.map { $0.addingTimeInterval(isHost ? 0 : -clockOffset) } ?? Date()
        // The hunt's clock starts after its intro.
        let leadIn = state.phase == .hunting ? Self.huntLeadIn : 0
        let begins = started.addingTimeInterval(leadIn)
        let ends = begins.addingTimeInterval(TimeInterval(state.phaseSeconds))
        if deadline.map({ abs($0.timeIntervalSince(ends)) > 0.2 }) ?? true { deadline = ends }
        if state.phase == .hunting {
            if huntStartsAt.map({ abs($0.timeIntervalSince(begins)) > 0.2 }) ?? true { huntStartsAt = begins }
        } else if huntStartsAt != nil {
            huntStartsAt = nil
        }
    }

    /// Starting the shared session gives this device a new AR session ID; the others need
    /// it to recognise us when ARKit merges our maps.
    private func sessionChanged(_ id: UUID?) {
        guard let id, inRoom, state.players.contains(where: { $0.id == me.id }), me.arSession != id else { return }
        me.arSession = id
        send(.join(me))
    }

    /// Synced once this device shares the host's reference point in the room: the host as
    /// soon as it has put it down, a guest once its map has merged with the host's and the
    /// point has arrived. Only with the host — it used to be with every other device, which
    /// with four players meant twelve merges and a lot of pointing at the same bookshelf.
    private func checkSynced() {
        guard state.phase == .syncing, !state.synced.contains(me.id), ar.squadOrigin != nil else { return }
        send(.synced(me.id))
    }

    /// Sends this device's map of the room to the others as hiding starts, then again
    /// while people hide whenever it has grown by a good amount (it fills in as they walk
    /// round), and once more when the hunt starts. Not constantly: it's a few hundred
    /// kilobytes each time.
    private func startMapping() {
        guard mappingTask == nil else { return }
        ar.beginRoomScan()
        mappingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            var first = true
            while !Task.isCancelled {
                guard let self, self.state.phase == .hiding else { return }
                await self.sendRoomMap(onlyIfGrown: !first)
                first = false
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func sendRoomMap(onlyIfGrown: Bool) async {
        guard let map = await ar.roomMapData() else { return }
        guard !onlyIfGrown || Double(map.triangles) > Double(lastMapTriangles) * 1.15 else { return }
        lastMapTriangles = map.triangles
        link.sendResource(map.data, named: "room")
    }

    private func stopMapping() {
        mappingTask?.cancel()
        mappingTask = nil
        lastMapTriangles = 0
    }

    /// My chameleons' camouflage, so everyone starts the hunt seeing what I left.
    private func sendSkins() {
        for chameleon in state.chameleons where chameleon.owner == me.id && !skinsSent.contains(chameleon.id) {
            guard let jpeg = ar.scatter.skinJPEG(chameleon.id) else { continue }
            skinsSent.insert(chameleon.id)
            link.sendResource(jpeg, named: "skin:\(chameleon.id.uuidString)")
        }
    }

    private func announceFinds(from previous: SquadState, to next: SquadState) {
        for chameleon in next.chameleons where chameleon.foundBy != nil {
            guard previous.chameleons.first(where: { $0.id == chameleon.id })?.foundBy == nil else { continue }
            let finder = chameleon.foundBy == me.id ? "YOU" : (player(chameleon.foundBy)?.name.uppercased() ?? "?")
            let owner = chameleon.owner == me.id ? "YOURS" : "\((player(chameleon.owner)?.name ?? "?").uppercased())'S"
            lastEvent = "\(finder) FOUND \(owner)"
            lastEventBy = player(chameleon.foundBy)
            // Your own finds already chimed when you tapped.
            if chameleon.foundBy != me.id { Sound.shared.play(.foundOther) }
            if chameleon.foundBy == me.id {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Paid now that the host has counted it, by how far into the hunt it is.
                let total = TimeInterval(next.settings.huntSeconds)
                let elapsed = total - (deadline.map { max(0, $0.timeIntervalSinceNow) } ?? total)
                let coins = CoinRules.find(base: CoinRules.findBase(next.settings.difficulty), elapsed: elapsed, of: total,
                                           hintOn: hintUsed)
                coinsFromFinds += coins
                Wallet.shared.earn(coins)
            }
        }
    }

    // MARK: - The host's clock

    private func hostAdvance() {
        guard isHost else { return }
        switch state.phase {
        case .syncing where SquadRules.everyoneSynced(state):
            schedule(after: 1.2) { $0.applyAsHost(.startHiding) }
        case .hiding:
            if SquadRules.everyoneDoneHiding(state), !state.chameleons.isEmpty {
                schedule(after: 0.8) { $0.applyAsHost(.startHunt) }
            } else {
                // No limit: only everyone being done moves it on. Otherwise, the clock,
                // plus the time it takes to place the rest for anyone who ran out.
                let allowance = TimeInterval(state.settings.autoPlaceAllowance)
                schedule(until: deadline?.addingTimeInterval(allowance)) { game in
                    if game.state.chameleons.isEmpty { game.applyAsHost(.backToLobby) } else { game.applyAsHost(.startHunt) }
                }
            }
        case .hunting:
            if SquadRules.allFound(state) || SquadRules.everyoneGaveUp(state) {
                schedule(after: 1.5) { $0.applyAsHost(.endRound) }
            } else {
                // A moment's grace: a find tapped in the last second may still be on its way.
                schedule(until: deadline?.addingTimeInterval(Self.claimGrace)) { $0.applyAsHost(.endRound) }
            }
        default:
            hostTimer?.cancel()
            hostTimer = nil
        }
    }

    private func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor (SquadGame) -> Void) {
        schedule(until: Date().addingTimeInterval(seconds), action)
    }

    private func schedule(until date: Date?, _ action: @escaping @MainActor (SquadGame) -> Void) {
        hostTimer?.cancel()
        guard let date else { return }
        let phaseNumber = state.phaseNumber
        let phase = state.phase
        hostTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.state.phase == phase, self.state.phaseNumber == phaseNumber else { return }
            action(self)
        }
    }

    #if DEBUG
    /// Testing: the next claim this guest sends goes missing, as when the connection blinks.
    var debugLoseNextClaim = false

    /// Plays a round with no camera, for testing the game between two Simulators over the
    /// network: syncs at once, hides `hide` chameleons nowhere in particular (finishing
    /// early only if that's the full number), finds `finds` of the others' in the hunt, then
    /// gives up. Writes the scoreboard to the log (SquadLog) at the end.
    func debugAutoPlay(hide: Int, finds: Int, settings: SquadSettings? = nil) {
        Task { @MainActor [weak self] in
            var placed = 0, found = 0, reported = false
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(0.5))
                guard let self else { return }
                if self.isHost, let settings, self.state.phase == .lobby, self.state.settings != settings {
                    self.setSettings(settings)
                }
                switch self.state.phase {
                case .syncing where !self.state.synced.contains(self.me.id):
                    self.send(.synced(self.me.id))
                case .hiding where placed < hide && SquadRules.canHide(self.me.id, in: self.state):
                    self.send(.placed(SquadChameleon(id: UUID(), owner: self.me.id, pose: "standing", scale: 0.8)))
                    placed += 1
                    if placed == self.state.settings.hiding { self.finishHiding() }
                case .hunting where self.huntIsLive:
                    if found < finds, let target = SquadRules.findable(for: self.me.id, in: self.state).first(where: { !self.pendingClaims.contains($0.id) }) {
                        self.claim(target.id)
                        found += 1
                    } else if found >= finds, self.pendingClaims.isEmpty, SquadRules.canSeek(self.me.id, in: self.state) {
                        self.giveUp()
                    }
                case .results where !reported:
                    reported = true
                    let board = SquadRules.scores(self.state).map { "\($0.player.name) \($0.finds)+\($0.survivors)=\($0.points)" }
                    SquadLog.note("scores: " + board.joined(separator: ", "))
                    return
                default:
                    break
                }
            }
        }
    }

    /// Lays out the squad screens in the Simulator, which has no second device.
    func debugFill(phase: SquadPhase, host: Bool, mode: SquadMode = .freeForAll, doneHiding: Bool = false,
                   lidar: [Bool] = [true, true, true, true]) {
        roomCode = "KXQV"
        debugInRoom = true
        let names = ["Ana", "Ben", "Cy", "Dee"]
        // The host joined first; a guest is Ben.
        let mine = host ? 0 : 1
        var next = SquadState()
        me = SquadPlayer(id: me.id, name: names[mine], colour: 0, arSession: UUID(), lidar: lidar[mine])
        for (index, name) in names.enumerated() {
            let player = index == mine ? me : SquadPlayer(id: UUID(), name: name, colour: 0, arSession: UUID(), lidar: lidar[index])
            SquadRules.apply(.join(player), to: &next)
        }
        next.phase = phase
        next.round = 1
        next.settings.mode = mode
        if mode == .hiderVsAll { next.hider = next.players[mine == 1 ? 2 : 1].id }
        if phase == .hiding { next.doneHiding = Set(next.players.map(\.id).filter { !SquadRules.canHide($0, in: next) }) }
        if doneHiding { next.doneHiding.formUnion([me.id, next.players[2].id]) }
        next.phaseSeconds = phase == .hunting ? 120 : 60
        if phase == .syncing { next.synced = [next.players[0].id, next.players[1].id] }
        if phase == .hunting || phase == .results || phase == .hiding {
            for (index, player) in next.players.enumerated() where SquadRules.canHide(player.id, in: next) {
                for n in 0..<(mode == .hiderVsAll ? 8 : 3) {
                    var c = SquadChameleon(id: UUID(), owner: player.id, pose: "standing", scale: 0.8)
                    if phase != .hiding, (index + n) % 3 == 0 {
                        c.foundBy = next.players[(index + 1) % next.players.count].id
                    }
                    next.chameleons.append(c)
                }
            }
        }
        state = next
        if host { link.debugPretendHost() }
        deadline = phase == .hunting || phase == .hiding ? Date().addingTimeInterval(TimeInterval(next.phaseSeconds)) : nil
        lastEvent = phase == .hunting ? "BEN FOUND CY'S" : nil
        lastEventBy = phase == .hunting ? next.players[1] : nil
        coinsFromFinds = phase == .hunting || phase == .results ? 56 : 0
        coinsForUnfound = phase == .results ? 20 : 0
        coinsForWinning = phase == .results ? 30 : 0
    }

    /// Hiding, out of time, with the rest being placed for this player.
    func debugAutoPlacing() {
        deadline = Date().addingTimeInterval(-1)
        autoPlacing = true
    }

    /// The hunt with the hint switched on (finds at half).
    func debugHintOn() { hintUsed = true }

    /// The hunt with `seconds` left (the hint unlocks halfway).
    func debugSecondsLeft(_ seconds: TimeInterval) {
        // As if the host started the hunt long enough ago (the clock maths is updateDeadline's).
        let gone = TimeInterval(state.phaseSeconds) - seconds
        state.phaseStartedAt = Date().addingTimeInterval(-gone - Self.huntLeadIn)
        updateDeadline()
    }

    /// The lobby with a difficulty picked.
    func debugDifficulty(_ difficulty: HuntDifficulty) { state.settings.difficulty = difficulty }

    /// A hunt on Hard, just after a miss.
    func debugMissed() {
        state.settings.difficulty = .hard
        // Long enough to still be showing once the hunt's intro has gone.
        missLockedUntil = Date().addingTimeInterval(TimeInterval(HuntDifficulty.hard.missPenalty) + 7.4)
    }

    /// This player has given up the hunt.
    func debugGiveUp() {
        state.gaveUp.insert(me.id)
        lastEvent = nil
    }

    /// The hunt's intro, held on screen for `seconds`.
    func debugHuntIntro(seconds: TimeInterval) {
        debugFill(phase: .hunting, host: true)
        for index in state.chameleons.indices { state.chameleons[index].foundBy = nil }
        // As if the host started the hunt just now, less the intro, so the clock maths
        // (updateDeadline) holds the intro for `seconds`.
        state.phaseStartedAt = Date().addingTimeInterval(seconds - Self.huntLeadIn)
        updateDeadline()
    }
    #endif
}
