//
//  PeerLink.swift
//  The wire between devices in a squad game: nearby phones and iPads on the same Wi-Fi
//  (or just Bluetooth), found and connected by MultipeerConnectivity. No accounts, no
//  server, nothing leaves the room.
//
//  One device hosts and advertises a room with a four-letter code; the others browse,
//  see the room and join it. Everything goes through the host — guests send only to
//  the host, and the host passes on whatever others need (AR map updates, chameleon
//  skins) — so the game never depends on every guest reaching every other guest.
//
//  Each packet starts with one byte saying what it is: a game message (JSON), or raw AR
//  collaboration data (which ARKit uses to merge everyone's view of the room) — the parts
//  ARKit says must arrive sent reliably, the rest allowed to drop, and relayed the same way.
//
//  Anything big — a LiDAR device's map of the room, a chameleon's camouflage — goes as a
//  resource (a file transfer), never as a message. Big messages on the reliable channel
//  queue everything behind them: in testing, a round's worth of camouflage sent that way
//  held up a seeker's taps for a minute and the end of the round with them.
//

import Foundation
import MultipeerConnectivity

@MainActor
final class PeerLink: NSObject, ObservableObject {

    static let serviceType = "chamhunt"

    struct Room: Identifiable, Hashable {
        let peer: MCPeerID
        let host: String
        let code: String
        /// Still in the lobby, so new players can join. A game under way stays findable
        /// only so its own players can get back in after dropping off.
        var open = true
        var id: MCPeerID { peer }
    }

    enum Role { case host, guest }

    @Published private(set) var rooms: [Room] = []
    @Published private(set) var connected: [MCPeerID] = []
    @Published private(set) var role: Role?
    /// The host this guest is connected to.
    @Published private(set) var hostPeer: MCPeerID?
    /// Bumped each time a room turns us away or doesn't answer in time.
    @Published private(set) var joinFailures = 0
    /// Host: whether someone asking to join is already in this game (and so may come back
    /// in mid-game, when nobody new can).
    var isReturning: ((UUID) -> Bool)?

    var onMessage: ((SquadMessage, MCPeerID) -> Void)?
    var onCollaboration: ((Data) -> Void)?
    /// A resource arrived: its name and its contents.
    var onResource: ((String, Data) -> Void)?
    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?

    private(set) var me: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var accepting = true
    private var hostCode = ""
    private var hostName = ""
    /// The room this guest asked to join. Players in a room are all connected to each
    /// other, so the first peer to connect isn't necessarily the host; this one is.
    private var invitedHost: MCPeerID?

    private enum Kind: UInt8 { case message = 1, collaboration = 2, optionalCollaboration = 4 }

    init(name: String) {
        me = MCPeerID(displayName: String(name.prefix(40)))
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    /// Start a room and wait for friends.
    func host(code: String, name: String) {
        stop()
        role = .host
        accepting = true
        hostCode = code
        hostName = name
        advertise()
    }

    /// Says the room is here, and whether it's open to new players.
    private func advertise() {
        advertiser?.stopAdvertisingPeer()
        let info = ["code": hostCode, "host": String(hostName.prefix(30)), "open": accepting ? "1" : "0"]
        let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: info, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    /// Stop letting new people in once the game's under way (they can join the next
    /// lobby). The room drops off everyone else's list, but its own players can still
    /// find it to get back in.
    func setAccepting(_ open: Bool) {
        guard open != accepting else { return }
        accepting = open
        if role == .host { advertise() }
    }

    /// Back from the background: advertising may have stopped while the app was away.
    func resumeAdvertising() {
        if role == .host { advertise() }
    }

    /// Look for rooms nearby.
    func browse() {
        stop()
        role = .guest
        let browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    /// Asks to join, saying who we are, so a game under way can let its own players back.
    func join(_ room: Room, as player: UUID) {
        invitedHost = room.peer
        browser?.invitePeer(room.peer, to: session, withContext: Data(player.uuidString.utf8), timeout: 15)
    }

    /// `lingering`: keep the old connection open a moment so a last message (the host's
    /// goodbye) gets out; everything else starts afresh straight away.
    func stop(lingering: Bool = false) {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        let old = session
        if lingering {
            let box = UncheckedSendable(value: old)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                box.value.disconnect()
            }
        } else {
            old.disconnect()
        }
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        rooms = []
        connected = []
        hostPeer = nil
        invitedHost = nil
        role = nil
    }

    func rename(_ name: String) {
        guard name != me.displayName, role == nil else { return }
        me = MCPeerID(displayName: String(name.prefix(40)))
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    // MARK: - Sending

    /// A game message. Guests can only talk to the host; the host to anyone.
    func send(_ message: SquadMessage, to peers: [MCPeerID]? = nil) {
        guard let body = try? JSONEncoder().encode(message) else { return }
        send(kind: .message, body: body, to: peers, reliable: true)
    }

    /// ARKit's map updates. The critical ones must arrive; the rest can be dropped.
    func sendCollaboration(_ data: Data, reliable: Bool, except excluded: MCPeerID? = nil) {
        let peers = targets(nil).filter { $0 != excluded }
        send(kind: reliable ? .collaboration : .optionalCollaboration, body: data, to: peers, reliable: reliable)
    }

    /// Something big, as a file transfer so it doesn't hold up the game's messages.
    func sendResource(_ data: Data, named name: String, except excluded: MCPeerID? = nil) {
        let recipients = targets(nil).filter { $0 != excluded }
        guard !recipients.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("squad-\(UUID().uuidString)")
        guard (try? data.write(to: url)) != nil else { return }
        for peer in recipients {
            // No completion handler. MultipeerConnectivity calls it on its own queue, and a
            // closure written here would be main-actor-only: Swift 6 stops the app when
            // one of those runs anywhere else — the squad crash in testing, 2 s into
            // hiding, the first time the room map was sent.
            session.sendResource(at: url, withName: name, toPeer: peer, withCompletionHandler: nil)
        }
        // The transfers read the file as they go; tidy it up once they've surely finished.
        Task.detached {
            try? await Task.sleep(for: .seconds(120))
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func targets(_ peers: [MCPeerID]?) -> [MCPeerID] {
        if role == .guest { return hostPeer.map { [$0] } ?? [] }
        return peers ?? connected
    }

    private func send(kind: Kind, body: Data, to peers: [MCPeerID]?, reliable: Bool) {
        let recipients = targets(peers)
        guard !recipients.isEmpty else { return }
        var packet = Data([kind.rawValue])
        packet.append(body)
        try? session.send(packet, toPeers: recipients, with: reliable ? .reliable : .unreliable)
    }

    // MARK: - Receiving

    /// Callbacks can still arrive from a session that's since been replaced; they're stale.
    fileprivate func isCurrent(_ id: ObjectIdentifier) -> Bool { id == ObjectIdentifier(session) }

    fileprivate func received(_ data: Data, from peer: MCPeerID) {
        guard let first = data.first, let kind = Kind(rawValue: first) else { return }
        let body = data.dropFirst()
        switch kind {
        case .message:
            if let message = try? JSONDecoder().decode(SquadMessage.self, from: Data(body)) {
                onMessage?(message, peer)
            }
        case .collaboration, .optionalCollaboration:
            onCollaboration?(Data(body))
            // The host passes AR map updates on, so every device can merge with every other —
            // the droppable ones still droppable.
            if role == .host { sendCollaboration(Data(body), reliable: kind == .collaboration, except: peer) }
        }
    }

    fileprivate func receivedResource(_ name: String, _ data: Data, from peer: MCPeerID) {
        onResource?(name, data)
        // Everything goes through the host, big things included.
        if role == .host { sendResource(data, named: name, except: peer) }
    }

    fileprivate func peerChanged(_ peer: MCPeerID, to state: MCSessionState) {
        #if DEBUG
        SquadLog.note("peer \(peer.displayName) -> \(state.rawValue) role=\(String(describing: role)) host=\(hostPeer?.displayName ?? "-")")
        #endif
        switch state {
        case .connected:
            if !connected.contains(peer) { connected.append(peer) }
            if role == .guest, hostPeer == nil, peer == invitedHost {
                hostPeer = peer
                invitedHost = nil
                // No longer looking, so the list would only go stale.
                browser?.stopBrowsingForPeers()
                rooms = []
            }
            onConnected?(peer)
        case .notConnected:
            connected.removeAll { $0 == peer }
            // Turned away, or no answer.
            if role == .guest, hostPeer == nil, peer == invitedHost {
                invitedHost = nil
                joinFailures += 1
            }
            // Tell the game first, while it can still see this was the host.
            onDisconnected?(peer)
            if peer == hostPeer { hostPeer = nil }
        default:
            break
        }
    }

    fileprivate func found(_ peer: MCPeerID, info: [String: String]?) {
        guard let code = info?["code"] else { return }
        let room = Room(peer: peer, host: info?["host"] ?? peer.displayName, code: code, open: info?["open"] != "0")
        rooms.removeAll { $0.peer == peer }
        rooms.append(room)
        rooms.sort { $0.host < $1.host }
    }

    fileprivate func lost(_ peer: MCPeerID) {
        rooms.removeAll { $0.peer == peer }
    }

    #if DEBUG
    /// For laying out the host's screens in the Simulator.
    func debugPretendHost() { role = .host }

    /// For laying out the room list in the Simulator.
    func debugRooms() {
        role = .guest
        rooms = [("Ben", "KXQV"), ("Dee", "MPRT")].map { Room(peer: MCPeerID(displayName: $0.0), host: $0.0, code: $0.1) }
    }
    #endif

    fileprivate func invited(by peer: MCPeerID, context: Data?, reply: @escaping (Bool, MCSession?) -> Void) {
        let player = context.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UUID.init(uuidString:))
        let returning = player.map { isReturning?($0) ?? false } ?? false
        let open = returning || (accepting && connected.count < SquadState.maximumPlayers - 1)
        reply(open, open ? session : nil)
    }
}

// MARK: - MultipeerConnectivity callbacks (they arrive on background queues)

extension PeerLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let box = UncheckedSendable(value: peerID)
        let from = ObjectIdentifier(session)
        Task { @MainActor in
            guard self.isCurrent(from) else { return }
            self.peerChanged(box.value, to: state)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let box = UncheckedSendable(value: peerID)
        let from = ObjectIdentifier(session)
        Task { @MainActor in
            guard self.isCurrent(from) else { return }
            self.received(data, from: box.value)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // The file is gone once this returns, so read it now.
        guard error == nil, let localURL, let data = try? Data(contentsOf: localURL) else { return }
        let box = UncheckedSendable(value: peerID)
        let from = ObjectIdentifier(session)
        Task { @MainActor in
            guard self.isCurrent(from) else { return }
            self.receivedResource(resourceName, data, from: box.value)
        }
    }
}

extension PeerLink: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let box = UncheckedSendable(value: (peerID, invitationHandler))
        Task { @MainActor in self.invited(by: box.value.0, context: context, reply: box.value.1) }
    }
}

extension PeerLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        let box = UncheckedSendable(value: peerID)
        Task { @MainActor in self.found(box.value, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let box = UncheckedSendable(value: peerID)
        Task { @MainActor in self.lost(box.value) }
    }
}

#if DEBUG
/// Debug builds: squad connection events, appended to Documents/squad.log, for testing
/// reconnects between Simulators (xcrun simctl get_app_container <device> <bundle> data).
enum SquadLog {
    static func note(_ text: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("squad.log")
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif
