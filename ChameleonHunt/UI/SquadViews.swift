//
//  SquadViews.swift
//  The squad game's screens: finding or hosting a room, the lobby, then — over the
//  camera — syncing up, hiding, the hunt and the podium. Same show as the rest
//  (HuntKit.swift), with the crew front and centre: every player is their own coloured
//  chameleon, lined up in the lobby, in the spotlight when they hide, on the podium when
//  they win.
//

import SwiftUI

/// Everything in squad play, picked by where the game is.
struct SquadView: View {
    @ObservedObject var store: GameStore
    @ObservedObject var squad: SquadGame
    @ObservedObject var ar: ARSessionController
    @Environment(\.showNotice) private var showNotice

    private var phase: SquadPhase { squad.state.phase }
    private var onCamera: Bool { squad.inRoom && phase != .lobby }

    var body: some View {
        ZStack {
            // The one AR view for squad play; the session carries on underneath the lobby.
            if onCamera {
                ARViewContainer(controller: ar).ignoresSafeArea()
                if phase == .hunting || phase == .results {
                    ChameleonTagLayer(tags: ar.tags)
                }
            }
            content.transition(.opacity)
            if squad.reconnecting {
                // The game carries on underneath; this just says why nothing's arriving.
                HStack(spacing: 10) {
                    LoadingDots(size: 7)
                    Text("Reconnecting to \(squad.hostName)").font(.hunt(19, relativeTo: .headline)).foregroundStyle(Hunt.ink)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .sticker(Hunt.sun, radius: 22, shadow: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 110)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: squad.reconnecting)
        .onChange(of: squad.hostLost) { _, lost in
            guard lost else { return }
            showNotice(Notice(title: "Host left", message: "The game's over. Find another room, or host your own.",
                              systemImage: "wifi.exclamationmark", tint: Hunt.cyan,
                              primary: .init(title: "OK") { [squad] in squad.browse() }))
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
        .animation(.easeInOut(duration: 0.25), value: squad.inRoom)
    }

    @ViewBuilder private var content: some View {
        if !squad.inRoom {
            SquadHomeView(store: store, squad: squad)
        } else {
            switch phase {
            case .lobby:
                SquadLobbyView(squad: squad)
            case .syncing:
                SquadSyncHUD(squad: squad, ar: ar)
            case .hiding:
                if !squad.canHide {
                    LookAwayView(squad: squad)
                } else if squad.state.doneHiding.contains(squad.me.id) {
                    SquadWaitView(squad: squad)
                } else {
                    SquadHideHUD(squad: squad, ar: ar, scatter: ar.scatter)
                }
            case .hunting:
                SquadHuntHUD(squad: squad, ar: ar)
            case .results:
                SquadResultsView(squad: squad, ar: ar)
            }
        }
    }
}

/// Name tags over the chameleons (ChameleonTags): who found each one — a magnifier and
/// their name, in their colour — and at the end, whose the unfound ones were.
private struct ChameleonTagLayer: View {
    @ObservedObject var tags: ChameleonTags

    var body: some View {
        ZStack {
            ForEach(tags.tags) { tag in
                HStack(spacing: 5) {
                    Image(systemName: symbol(tag.kind))
                        .font(.system(size: 12, weight: .black))
                    Text(tag.name).font(.hunt(16, relativeTo: .caption)).lineLimit(1)
                }
                .foregroundStyle(Hunt.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .sticker(tag.colour, radius: 10, shadow: 2)
                .fixedSize()
                .position(x: tag.point.x, y: tag.point.y - 20)
                .accessibilityLabel(tag.name)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.08), value: tags.tags)
    }

    private func symbol(_ kind: ChameleonTags.Tag.Kind) -> String {
        switch kind {
        case .found: "magnifyingglass"
        case .notFound: "eye.slash.fill"
        case .mine: "person.fill"
        }
    }
}

// MARK: - Finding a room

private struct SquadHomeView: View {
    @ObservedObject var store: GameStore
    @ObservedObject var squad: SquadGame
    @State private var joining: PeerLink.Room?
    @Environment(\.showNotice) private var showNotice

    /// Games that are still in their lobby; one already under way can't take new players.
    private var rooms: [PeerLink.Room] { squad.link.rooms.filter(\.open) }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            ZStack(alignment: .topLeading) {
                HuntBackground(focus: portrait ? UnitPoint(x: 0.5, y: 0.2) : UnitPoint(x: 0.25, y: 0.45))
                ScrollView {
                    let layout = portrait
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 40))
                    layout {
                        start.frame(maxWidth: portrait ? 600 : 440, alignment: .leading)
                        nearby.frame(maxWidth: 600)
                    }
                    .padding(.horizontal, Hunt.gutter)
                    .padding(.vertical, 100)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                IconButton(systemImage: "chevron.left", label: "Back", action: store.leaveSquad)
                    .padding(Hunt.gutter)
            }
        }
        .onAppear {
            if squad.link.role == nil { squad.browse() }
        }
        .onChange(of: squad.link.joinFailures) { _, _ in
            guard let room = joining else { return }
            joining = nil
            showNotice(Notice(title: "Couldn't join", message: "\(room.host)'s game may have just started, or be full. Try again in a moment.",
                              systemImage: "person.crop.circle.badge.xmark", tint: Hunt.cyan))
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: -18) {
                ForEach([0, 2, 3, 1], id: \.self) { i in
                    MascotImage(pose: .standing, view: .hero, resolution: 240, tint: Hunt.playerTint(i))
                        .frame(width: 84, height: 84)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Headline(text: "Squad", size: 72, colour: Hunt.cyan)
                Text("Same Wi-Fi. Up to 6.")
                    .font(.chat(.title3, weight: .bold))
                    .foregroundStyle(Hunt.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Your name")
                NameField(name: $store.playerName, colour: squad.me.colour)
            }
            Button(action: squad.host) {
                Label("Host a game", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(HuntButtonStyle(large: true, fill: true))
        }
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Games nearby")
                Spacer()
                if !rooms.isEmpty { SearchingDot() }
            }
            if rooms.isEmpty {
                VStack(spacing: 14) {
                    SearchingDot(size: 60)
                    Text("Looking for games…")
                        .font(.hunt(24, relativeTo: .title3))
                        .foregroundStyle(Hunt.text)
                    Text("When a friend hosts, their game shows up here.")
                        .font(.chat(.subheadline, weight: .bold))
                        .foregroundStyle(Hunt.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .huntPanel()
            } else {
                VStack(spacing: 14) {
                    ForEach(rooms) { room in roomRow(room) }
                }
            }
        }
    }

    private func roomRow(_ room: PeerLink.Room) -> some View {
        HStack(spacing: 14) {
            // The host always joins their own room first, so they always have the first colour.
            Avatar(name: room.host, colour: 0, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.host).font(.hunt(24, relativeTo: .title3)).foregroundStyle(Hunt.ink)
                Text(room.code).font(.hunt(16, relativeTo: .subheadline)).tracking(2).foregroundStyle(Hunt.ink)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .sticker(Hunt.sun, radius: 8, shadow: 2)
            }
            Spacer(minLength: 8)
            Button {
                joining = room
                squad.join(room)
                Task {
                    try? await Task.sleep(for: .seconds(16))
                    if joining == room { joining = nil }
                }
            } label: {
                if joining == room {
                    LoadingDots().frame(width: 56)
                } else {
                    Label("Join", systemImage: "arrow.right")
                }
            }
            .buttonStyle(.huntPrimary)
            .disabled(joining != nil)
        }
        .padding(14)
        .sticker(Hunt.paper)
        .accessibilityElement(children: .contain)
    }
}

/// A slowly pulsing dot: still looking.
private struct SearchingDot: View {
    var size: CGFloat = 16
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Hunt.cyan.opacity(pulse ? 0 : 0.8), lineWidth: 3)
                .scaleEffect(pulse ? 2.2 : 1)
            Circle().fill(Hunt.cyan).frame(width: size * 0.55, height: size * 0.55)
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 2))
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel("Searching")
    }
}

/// Which squad game this room gets, from who has LiDAR (SquadRules.roomSupport).
private struct RoomSupportBadge: View {
    @ObservedObject var squad: SquadGame

    var body: some View {
        let (symbol, text, colour): (String, String, Color) = switch squad.roomSupport {
        case .full:
            ("checkmark.seal.fill", "Full game", Hunt.lime)
        case .shared(let scanner):
            ("dot.radiowaves.left.and.right",
             scanner == squad.me.id ? "You map the room for everyone" : "\(squad.player(scanner)?.name ?? "One device") maps the room for everyone",
             Hunt.paper)
        case .flat:
            // Paper, not sun or a player's colour: those mean time, first place and players.
            ("square.dashed", "Lite · flat surfaces only", Hunt.paper)
        }
        return Label(text, systemImage: symbol)
            .font(.hunt(18, relativeTo: .headline))
            .foregroundStyle(Hunt.ink)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .sticker(colour, radius: 14, shadow: 3)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: squad.roomSupport)
    }
}

/// The small label above a group.
private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.hunt(18, relativeTo: .headline))
            .foregroundStyle(Hunt.text)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Lobby

private struct SquadLobbyView: View {
    @ObservedObject var squad: SquadGame

    private var settings: SquadSettings { squad.state.settings }
    private var joined: Bool { squad.state.players.contains { $0.id == squad.me.id } }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            // A phone on its side: both columns start at the top (the tall host card used to
            // push the room sign halfway off the screen) and the sign is smaller.
            let short = !portrait && proxy.size.height < 500
            ZStack(alignment: .topLeading) {
                HuntBackground(focus: portrait ? UnitPoint(x: 0.5, y: 0.25) : UnitPoint(x: 0.28, y: 0.5))
                if joined {
                    ScrollView {
                        let layout = portrait
                            ? AnyLayout(VStackLayout(alignment: .center, spacing: 28))
                            : AnyLayout(HStackLayout(alignment: short ? .top : .center, spacing: short ? 24 : 36))
                        layout {
                            room(width: portrait ? proxy.size.width - Hunt.gutter * 2 : proxy.size.width * 0.46, short: short)
                            rules.frame(maxWidth: 560)
                        }
                        .padding(.horizontal, Hunt.gutter)
                        .padding(.top, short ? 24 : 90)
                        .padding(.bottom, short ? Hunt.gutter : 90)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    VStack(spacing: 16) {
                        LoadingDots(colour: Hunt.text, size: 16)
                        Headline(text: "Joining", size: 44)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                IconButton(systemImage: "chevron.left", label: "Leave room") { squad.browse() }
                    .padding(Hunt.gutter)
            }
        }
    }

    /// The room code on a sign, and the crew lined up under it.
    private func room(width: CGFloat, short: Bool = false) -> some View {
        let count = max(squad.state.players.count, 1)
        let size = min(short ? 84 : 118, (width - CGFloat(count - 1) * 8) / CGFloat(count) / 1.1)
        return VStack(spacing: short ? 14 : 22) {
            VStack(spacing: -4) {
                Text("ROOM").font(.hunt(short ? 16 : 20, relativeTo: .headline)).foregroundStyle(Hunt.ink)
                Text(squad.roomCode).font(.hunt(short ? 54 : 76, relativeTo: .largeTitle)).tracking(6).foregroundStyle(Hunt.ink)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
            .sticker(Hunt.sun, radius: 24, shadow: 6)
            .rotationEffect(.degrees(-3))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Room \(squad.roomCode.map(String.init).joined(separator: " "))")
            CrewLineup(players: squad.state.players, me: squad.me.id, hostID: squad.state.players.first?.id, size: size)
                .sensoryFeedback(.impact(weight: .medium), trigger: squad.state.players.count)
            Text("\(squad.state.players.count) of \(SquadState.maximumPlayers)")
                .font(.chat(.subheadline, weight: .bold))
                .foregroundStyle(Hunt.muted)
            RoomSupportBadge(squad: squad)
            // For friends in the room who don't have the game yet (once it's in the store).
            InviteCode()
        }
        .frame(width: width)
    }

    /// The host sets the game up; everyone else sees what's been picked, as a summary
    /// that doesn't look like controls (Among Us and Jackbox do the same), and who
    /// they're waiting for.
    @ViewBuilder private var rules: some View {
        if squad.isHost { hostRules } else { guestRules }
    }

    private var guestRules: some View {
        let host = squad.state.players.first
        let mode = settings.mode == .freeForAll
            ? (title: "Free-for-all", detail: "Everyone hides. Everyone hunts.", icon: "person.3.fill")
            : (title: "Hider vs all", detail: "One hides. The rest hunt.", icon: "person.fill.viewfinder")
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: mode.icon).font(.system(size: 26, weight: .black)).foregroundStyle(Hunt.ink)
                    .frame(width: 56, height: 56)
                    .sticker(Hunt.lime, radius: 16, shadow: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(mode.title.uppercased()).font(.hunt(28, relativeTo: .title2)).foregroundStyle(Hunt.text)
                    Text(mode.detail).font(.chat(.subheadline, weight: .bold)).foregroundStyle(Hunt.muted)
                }
            }
            HStack(spacing: 10) {
                Stat(value: settings.mode == .freeForAll ? "\(settings.perPlayer)" : "\(settings.swarm)",
                     label: settings.mode == .freeForAll ? "Each hides" : "Swarm")
                Stat(value: settings.hidingIsTimed ? GameConfig.stopwatch(settings.hideSeconds) : "∞", label: "Hide", colour: Hunt.sun)
                Stat(value: GameConfig.stopwatch(settings.huntSeconds), label: "Hunt", colour: Hunt.sun)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(settings.hints ? "Hint costs half your coins" : "No hints", systemImage: settings.hints ? "lightbulb.fill" : "lightbulb.slash.fill")
                Label(settings.difficulty.summary, systemImage: "gauge.with.needle.fill")
            }
            .font(.chat(.subheadline, weight: .bold))
            .foregroundStyle(Hunt.muted)
            HStack(spacing: 12) {
                if let host { Avatar(name: host.name, colour: host.colour, size: 36) }
                Text("Waiting for \(squad.hostName)").font(.hunt(20, relativeTo: .headline)).foregroundStyle(Hunt.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                LoadingDots(colour: Hunt.text)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Hunt.ink.opacity(0.35)))
        }
        .huntPanel(padding: 20)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: settings)
        // A tick when the host changes something, so guests notice.
        .sensoryFeedback(.selection, trigger: settings)
        .accessibilityElement(children: .combine)
    }

    private var hostRules: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Mode")
                // The same height side by side, whichever line is longer.
                HStack(spacing: 12) {
                    modeTile(.freeForAll, title: "Free-for-all", detail: "Everyone hides. Everyone hunts.", icon: "person.3.fill")
                    modeTile(.hiderVsAll, title: "Hider vs all", detail: "One hides. The rest hunt.", icon: "person.fill.viewfinder")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if settings.mode == .freeForAll {
                choice("Each hides", values: [1, 2, 3, 4, 5], selected: settings.perPlayer, title: { "\($0)" }) { value in
                    var next = settings; next.perPlayer = value; squad.setSettings(next)
                }
            } else {
                choice("Swarm size", values: [3, 5, 8, 10], selected: settings.swarm, title: { "\($0)" }) { value in
                    var next = settings; next.swarm = value; squad.setSettings(next)
                }
            }
            choice("Hide time", values: SquadSettings.hideChoices, selected: settings.hideSeconds,
                   title: { $0 == 0 ? "No limit" : GameConfig.stopwatch($0) }) { value in
                var next = settings; next.hideSeconds = value; squad.setSettings(next)
            }
            choice("Hunt time", values: SquadSettings.huntChoices, selected: settings.huntSeconds, title: GameConfig.stopwatch) { value in
                var next = settings; next.huntSeconds = value; squad.setSettings(next)
            }
            // The Hint key is there all hunt; each player chooses to use it, for half their coins.
            choice("Hints", values: [1, 0], selected: settings.hints ? 1 : 0, title: { $0 == 1 ? "On" : "Off" }) { value in
                var next = settings; next.hints = value == 1; squad.setSettings(next)
            }
            // The same levels as Swarm's, doing the same things.
            VStack(alignment: .leading, spacing: 8) {
                choice("Difficulty", values: Array(HuntDifficulty.allCases.indices),
                       selected: HuntDifficulty.allCases.firstIndex(of: settings.difficulty) ?? 0,
                       title: { HuntDifficulty.allCases[$0].title }) { value in
                    var next = settings; next.difficulty = HuntDifficulty.allCases[value]; squad.setSettings(next)
                }
                Text(settings.difficulty.detail)
                    .font(.chat(.subheadline, weight: .bold))
                    .foregroundStyle(Hunt.muted)
            }
            Button(action: squad.startSync) {
                Label(squad.state.players.count < 2 ? "Need 2 players" : "Start", systemImage: "play.fill")
            }
            .buttonStyle(HuntButtonStyle(large: true, fill: true))
            .disabled(squad.state.players.count < 2)
            .padding(.top, 4)
        }
        .huntPanel(padding: 20)
    }

    private func modeTile(_ mode: SquadMode, title: String, detail: String, icon: String) -> some View {
        let selected = settings.mode == mode
        return Button {
            var next = settings; next.mode = mode; squad.setSettings(next)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 24, weight: .black))
                Text(title.uppercased()).font(.hunt(22, relativeTo: .title3))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).font(.chat(.subheadline, weight: .bold)).foregroundStyle(Hunt.inkMuted)
                    .lineLimit(2).minimumScaleFactor(0.75)
            }
            .foregroundStyle(Hunt.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .sticker(selected ? Hunt.lime : Hunt.paper, radius: 18, shadow: selected ? 2 : 5)
            .offset(y: selected ? 3 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func choice(_ label: String, values: [Int], selected: Int, title: @escaping (Int) -> String,
                        choose: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: label)
            FlowChips(values: values, selected: selected, title: title, choose: choose)
        }
    }
}

// MARK: - Over the camera

/// Leaving mid-game asks first.
private struct LeaveButton: View {
    @ObservedObject var squad: SquadGame
    @Environment(\.showNotice) private var showNotice

    var body: some View {
        IconButton(systemImage: "xmark", label: "Leave game") { showNotice(leaveNotice(squad)) }
    }
}

@MainActor
private func leaveNotice(_ squad: SquadGame) -> Notice {
    Notice(title: "Leave the game?",
           message: squad.isHost ? "You're the host, so it ends for everyone." : "Your chameleons go with you.",
           systemImage: "door.left.hand.open", tint: Hunt.cherry,
           primary: .init(title: "Leave") { [squad] in squad.browse() },
           secondary: .init(title: "Stay"))
}

/// The hunt's menu, behind the key top left: things you do now and then, kept off the
/// camera so the room stays clear — seeing your own chameleons, giving up, leaving.
private struct SquadHuntMenu: View {
    @ObservedObject var squad: SquadGame
    @Binding var isPresented: Bool
    @Environment(\.showNotice) private var showNotice

    private var seeking: Bool { SquadRules.canSeek(squad.me.id, in: squad.state) }
    private var timeLeft: Bool { squad.deadline.map { Date() < $0 } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GAME").font(.hunt(20, relativeTo: .headline))
            if seeking {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { squad.showMine }, set: { squad.setShowMine($0) })) {
                        Label("Show mine", systemImage: "eye.fill")
                    }
                    .toggleStyle(PaperToggleStyle())
                    Text("Yours show see-through white, with a tag.")
                        .font(.rounded(13, .bold))
                        .foregroundStyle(Hunt.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if timeLeft {
                    Button {
                        isPresented = false
                        showNotice(giveUpNotice)
                    } label: { Label("Give up", systemImage: "flag.fill") }
                        .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
                }
            }
            Button {
                isPresented = false
                showNotice(leaveNotice(squad))
            } label: { Label("Leave game", systemImage: "door.left.hand.open") }
                .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
        }
        .foregroundStyle(Hunt.ink)
    }

    private var giveUpNotice: Notice {
        Notice(title: "Give up?", message: "You'll see where the rest are, and can't find any more.",
               systemImage: "flag.fill", tint: Hunt.cherry,
               primary: .init(title: "Keep looking"),
               secondary: .init(title: "Give up", systemImage: "flag.fill") { [squad] in squad.giveUp() })
    }
}

/// Who's where: a small roster over the camera, each player ticked off when ready.
private struct SyncRoster: View {
    @ObservedObject var squad: SquadGame
    let done: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(squad.state.players) { player in
                HStack(spacing: 10) {
                    Avatar(name: player.name, colour: player.colour, size: 30)
                    Text(player.id == squad.me.id ? "You" : player.name)
                        .font(.hunt(18, relativeTo: .headline)).foregroundStyle(Hunt.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    if squad.state.away.contains(player.id) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 16, weight: .black))
                            .foregroundStyle(Hunt.inkMuted)
                            .accessibilityLabel("Reconnecting")
                    } else if done.contains(player.id) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .black))
                            .foregroundStyle(Hunt.ink, Hunt.lime)
                            .accessibilityLabel("Ready")
                    } else {
                        LoadingDots(size: 6)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minWidth: 180, maxWidth: 250)
        .huntPlate(padding: 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
    }
}

/// Everyone points at the same bit of room until ARKit has merged their maps.
private struct SquadSyncHUD: View {
    @ObservedObject var squad: SquadGame
    @ObservedObject var ar: ARSessionController
    @State private var since = Date()

    private var allSynced: Bool { SquadRules.everyoneSynced(squad.state) }

    /// What helps ARKit match two views of a room, in turn, while it's taking a while.
    private static let tips: [(text: String, symbol: String)] = [
        ("Point at something with detail, like a shelf", "books.vertical.fill"),
        ("Move slowly, a little side to side", "arrow.left.and.right"),
        ("Stand close together, looking the same way", "person.2.fill"),
    ]

    private var synced: Bool { squad.state.synced.contains(squad.me.id) }
    /// Everyone only has to line up with the host (see SquadGame.checkSynced).
    private var detail: String {
        squad.isHost ? "Everyone points where you're pointing" : "Stand by \(squad.hostName). Point where they point."
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                CameraHeader(leading: LeaveButton(squad: squad), title: "Sync up", detail: detail) {
                    SyncRoster(squad: squad, done: squad.state.synced)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let waited = context.date.timeIntervalSince(since)
                    if let hint = ar.trackingHint {
                        CamHint(text: hint)
                    } else if synced, !allSynced {
                        CamHint(text: squad.isHost ? "Keep pointing there" : "Synced · waiting for the others",
                                systemImage: "checkmark.circle.fill", tint: Hunt.limeLip)
                    } else if !synced, waited > 6 {
                        let tip = Self.tips[Int(waited / 5) % Self.tips.count]
                        CamHint(text: tip.text, systemImage: tip.symbol)
                            .id(tip.text)
                            .transition(.opacity)
                    }
                }
                Spacer()
            }
            .padding(Hunt.gutter)
            if allSynced {
                Slam(text: "Synced", colour: Hunt.text, size: 88, burst: Hunt.lime).allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: allSynced)
        .sensoryFeedback(.success, trigger: squad.state.synced.contains(squad.me.id))
    }
}

/// Hiding: the same aim-and-drop as Swarm, against the clock.
private struct SquadHideHUD: View {
    @ObservedObject var squad: SquadGame
    @ObservedObject var ar: ARSessionController
    @ObservedObject var scatter: ScatterStage

    private var target: Int { squad.state.settings.hiding }
    private var mine: Int { scatter.records.filter { $0.hiddenBy.id == squad.me.id }.count }
    private var full: Bool { mine >= target }
    private var canDrop: Bool { ar.probe?.isPlaceable == true && !full && scatter.geometriesReady && scatter.previewReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraHeader(leading: LeaveButton(squad: squad),
                         title: squad.state.settings.mode == .hiderVsAll ? "Hide the swarm" : "Hide yours") {
                HUDPill(systemImage: "lizard.fill", text: "\(mine)/\(target)", tint: mine > 0 ? Hunt.limeLip : Hunt.ink)
                // No clock when the host set no limit.
                if squad.deadline != nil { Countdown(until: squad.deadline) { ClockPill(seconds: $0) } }
            }
            if squad.autoPlacing {
                // Out of time: the rest go down by themselves, wherever this is pointing.
                CamHint(text: "Time's up · placing the rest where you point", systemImage: "timer", tint: Hunt.sunLip)
            }
            if squad.isMapping {
                CamHint(text: "You're mapping the room · walk around", systemImage: "dot.radiowaves.left.and.right", tint: Hunt.cyan)
            }
            Group {
                if !scatter.geometriesReady {
                    CamHint(text: "Loading…", systemImage: "hourglass")
                } else if full {
                    CamHint(text: "All hidden", systemImage: "checkmark.circle.fill", tint: Hunt.limeLip)
                } else if !scatter.previewReady && mine > 0 {
                    CamHint(text: "Blending in…", systemImage: "wand.and.stars", tint: Hunt.limeLip)
                } else {
                    PlacementHints(ar: ar, blockedReason: ar.probe?.surface == nil && ar.probe != nil ? ar.noSurfaceHint : nil)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: scatter.previewReady)
            Spacer()
            ActionBar {
                Button(action: squad.undo) { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.huntSecondary)
                    .disabled(mine == 0 || squad.autoPlacing)
            } primary: {
                if full {
                    Button(action: squad.finishHiding) { Label("Done hiding", systemImage: "checkmark").frame(minWidth: 260) }
                        .buttonStyle(.huntBig)
                } else {
                    // While the rest are being placed, the key is theirs, not the player's.
                    PlaceButton(title: "Drop", enabled: canDrop && !squad.autoPlacing, action: squad.drop)
                        .sensoryFeedback(.impact(weight: .medium), trigger: mine)
                }
            } trailing: {
                // Against the clock everyone hides them all (the rest are placed if time
                // runs out). With no limit, stopping short is the only way on if someone
                // can't find anywhere for the last one.
                if !full, !squad.state.settings.hidingIsTimed {
                    Button(action: squad.finishHiding) { Label("Done hiding", systemImage: "checkmark") }
                        .buttonStyle(.huntSecondary)
                        .disabled(mine == 0)
                }
            }
        }
        .padding(Hunt.gutter)
    }
}

/// Hidden yours; the others are still at it.
/// Yours are all hidden: off the camera and onto the stage, with who's still hiding
/// (faded, with dots) and who's done (ticked), and the hide clock. The hunt's intro
/// follows as soon as the last one's done.
private struct SquadWaitView: View {
    @ObservedObject var squad: SquadGame

    var body: some View {
        let state = squad.state
        let hiders = state.players.filter { SquadRules.canHide($0.id, in: state) }
        let still = hiders.filter { !state.doneHiding.contains($0.id) }
        GeometryReader { proxy in
            let sideways = proxy.size.width > proxy.size.height && proxy.size.height < 500
            let roomy = min(proxy.size.width, proxy.size.height) > 600
            let count = max(hiders.count, 1)
            let width = sideways ? proxy.size.width * 0.5 : proxy.size.width - Hunt.gutter * 2
            let size = min(sideways ? 76 : roomy ? 150 : 110, (width - CGFloat(count - 1) * 8) / CGFloat(count) / 1.1)
            ZStack(alignment: .topLeading) {
                HuntBackground(focus: UnitPoint(x: 0.5, y: sideways ? 0.5 : 0.42))
                let layout = sideways ? AnyLayout(HStackLayout(spacing: 32)) : AnyLayout(VStackLayout(spacing: roomy ? 36 : 24))
                layout {
                    VStack(spacing: 10) {
                        Headline(text: "All hidden", size: sideways ? 48 : roomy ? 84 : 60)
                        Text(still.isEmpty ? "Everyone's ready" : "Waiting for \(still.map(\.name).formatted(.list(type: .and)))")
                            .font(.hunt(roomy ? 32 : 24, relativeTo: .title3))
                            .foregroundStyle(Hunt.text)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 20) {
                        CrewLineup(players: hiders, me: squad.me.id, size: size, ticked: state.doneHiding)
                        if squad.deadline != nil { Countdown(until: squad.deadline) { ClockPill(seconds: $0) } }
                    }
                }
                .padding(Hunt.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                LeaveButton(squad: squad).padding(Hunt.gutter)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: state.doneHiding)
    }
}

/// The start of the hunt, on every device at once: HUNT, whose chameleons you're after,
/// the colour your finds will turn, and 3-2-1. The hunt's clock starts when it's over.
private struct SquadHuntIntro: View {
    @ObservedObject var squad: SquadGame

    var body: some View {
        let state = squad.state
        let seeking = SquadRules.canSeek(squad.me.id, in: state)
        let hider = squad.player(state.hider)
        let owners = Set(state.chameleons.map(\.owner))
        // Whose you're after (or, for the hider, who's after yours).
        let crew = state.players.filter { player in
            if !seeking { return player.id != squad.me.id }
            return player.id != squad.me.id && owners.contains(player.id)
        }
        let line: String = if !seeking {
            "They're after yours"
        } else if state.settings.mode == .hiderVsAll, let hider {
            "Find \(hider.name)'s \(state.chameleons.count)"
        } else {
            "Find all \(SquadRules.findable(for: squad.me.id, in: state).count)"
        }
        GeometryReader { proxy in
            let sideways = proxy.size.width > proxy.size.height && proxy.size.height < 500
            let roomy = min(proxy.size.width, proxy.size.height) > 600
            let count = max(crew.count, 1)
            let width = sideways ? proxy.size.width * 0.45 : proxy.size.width - Hunt.gutter * 2
            let size = min(sideways ? 64 : roomy ? 140 : 96, (width - CGFloat(count - 1) * 8) / CGFloat(count) / 1.1)
            ZStack {
                HuntBackground(focus: UnitPoint(x: 0.5, y: 0.4))
                let layout = sideways ? AnyLayout(HStackLayout(spacing: 28)) : AnyLayout(VStackLayout(spacing: roomy ? 30 : 22))
                layout {
                    VStack(spacing: 14) {
                        Slam(text: "Hunt", colour: Hunt.text, size: sideways ? 70 : roomy ? 140 : 100, burst: Hunt.lime)
                        Text(line)
                            .font(.hunt(roomy ? 38 : 28, relativeTo: .title2))
                            .foregroundStyle(Hunt.text)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 18) {
                        CrewLineup(players: crew, me: squad.me.id, size: size)
                        if seeking {
                            // Finds turn the finder's colour; say which is yours.
                            HStack(spacing: 10) {
                                Avatar(name: squad.me.name, colour: squad.me.colour, size: 30)
                                Text("What you find turns \(Hunt.playerColourName(squad.me.colour))")
                                    .font(.hunt(19, relativeTo: .headline))
                                    .foregroundStyle(Hunt.ink)
                            }
                            .padding(.leading, 6)
                            .padding(.trailing, 14)
                            .padding(.vertical, 6)
                            .sticker(Hunt.player(squad.me.colour), radius: 16, shadow: 3)
                            .accessibilityElement(children: .combine)
                        }
                        Countdown(until: squad.huntStartsAt) { seconds in
                            ZStack {
                                if seconds > 0 && seconds <= 3 {
                                    Slam(text: "\(seconds)", colour: Hunt.text, size: sideways ? 48 : roomy ? 90 : 64,
                                         trigger: seconds, burst: Hunt.sun)
                                }
                            }
                            .frame(height: sideways ? 80 : roomy ? 150 : 110)
                        }
                    }
                }
                .padding(Hunt.gutter)
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// Hider vs all, for the hunters while the hider hides: the lights go down, the hider's
/// chameleon stands in the spotlight, and nobody watches.
private struct LookAwayView: View {
    @ObservedObject var squad: SquadGame

    var body: some View {
        let hider = squad.player(squad.state.hider)
        GeometryReader { proxy in
            // A phone on its side: the hider's chameleon beside the words, not above them
            // (the clock used to end up under the bottom edge).
            let sideways = proxy.size.width > proxy.size.height && proxy.size.height < 500
            ZStack(alignment: .topLeading) {
                SpotlightStage(colour: hider.map { Hunt.player($0.colour) } ?? Hunt.paper) {
                    let layout = sideways ? AnyLayout(HStackLayout(spacing: 28)) : AnyLayout(VStackLayout(spacing: 14))
                    layout {
                        if let hider {
                            let art: CGFloat = sideways ? 200 : 240
                            MascotImage(pose: .standing, view: .hero, resolution: 720, tint: Hunt.playerTint(hider.colour))
                                .frame(width: art, height: art)
                                .spotlightSubject()
                                .accessibilityHidden(true)
                        }
                        VStack(spacing: 14) {
                            Slam(text: "Look away", colour: Hunt.text, size: sideways ? 64 : 84)
                            if let hider {
                                HStack(spacing: 8) {
                                    Text("\(hider.name) is hiding \(squad.state.settings.swarm)")
                                    Image(systemName: "lizard.fill")
                                }
                                .font(.hunt(24, relativeTo: .title3))
                                .foregroundStyle(Hunt.ink)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .sticker(Hunt.player(hider.colour), radius: 16)
                                .accessibilityElement(children: .combine)
                            }
                            Countdown(until: squad.deadline) { ClockPill(seconds: $0) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Hunt.gutter)
                }
                LeaveButton(squad: squad).padding(Hunt.gutter)
            }
        }
    }
}

/// The hunt: the clock, what's left, the live scores, and who just found what.
private struct SquadHuntHUD: View {
    @ObservedObject var squad: SquadGame
    @ObservedObject var ar: ARSessionController
    @State private var showFound = false
    @State private var slams = 0
    @State private var feed: String?
    @State private var feedBy: SquadPlayer?
    /// The intro card (HUNT, who to find, 3-2-1) is up until the hunt's clock starts.
    @State private var introOver = false
    @State private var menuOpen = false
    @Environment(\.showNotice) private var showNotice

    private var seeking: Bool { SquadRules.canSeek(squad.me.id, in: squad.state) }
    private var gaveUp: Bool { squad.state.gaveUp.contains(squad.me.id) }
    private var penalty: Int { squad.state.settings.difficulty.missPenalty }
    /// Seconds until this player can tap again after a miss (read inside the clock's
    /// timeline, so it counts down).
    private var lockedFor: Int? {
        guard let until = squad.missLockedUntil else { return nil }
        let left = Int(ceil(until.timeIntervalSinceNow))
        return left > 0 ? left : nil
    }
    private var left: Int {
        seeking ? SquadRules.findable(for: squad.me.id, in: squad.state).count
                : squad.state.chameleons.filter { $0.foundBy == nil }.count
    }

    var body: some View {
        ZStack {
            // The hint's arrow, towards the nearest one still to find when it's off screen.
            if let direction = ar.offscreenDirection {
                OffscreenArrow(direction: direction).allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 12) {
                // On a phone the scores drop under the clock.
                RowOrColumnLayout(rowAlignment: .top, columnAlignment: .trailing, spacing: 12, columnSpacing: 10, spread: true) {
                    huntStatus.frame(maxWidth: .infinity, alignment: .leading)
                    MiniBoard(squad: squad)
                }
                if let feed {
                    // In the finder's colour: the same colour their find just turned.
                    HUDPill(systemImage: "sparkles", text: feed, tint: Hunt.ink,
                            fill: feedBy.map { Hunt.player($0.colour) } ?? Hunt.paper)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(feed)
                } else if let hint = ar.trackingHint {
                    CamHint(text: hint)
                }
                Spacer()
                Countdown(until: squad.deadline) { seconds in
                    VStack(spacing: 12) {
                        if seconds == 0 {
                            // The host ends the round; say so rather than sit there.
                            CamHint(text: "Time's up · waiting for \(squad.hostName)", systemImage: "hourglass")
                        } else if gaveUp {
                            CamHint(text: "You gave up · the rest are lit up", systemImage: "flag.fill")
                        } else if !seeking {
                            CamHint(text: "Watch them hunt", systemImage: "eye.fill")
                        } else if let wait = lockedFor {
                            // A miss on Medium or Hard: no taps for a few seconds.
                            CamHint(text: "Missed · wait \(wait) s", systemImage: "hand.raised.fill", tint: Hunt.cherry)
                        } else if squad.hintUsed {
                            CamHint(text: ar.hintTargetInView ? "It's in view" : "Follow the arrow",
                                    systemImage: ar.hintTargetInView ? "eye.fill" : "location.north.fill", tint: Hunt.sunLip)
                        } else if penalty > 0 {
                            CamHint(text: "Tap what you spot · a miss costs \(penalty) s", systemImage: "hand.tap.fill")
                        } else {
                            CamHint(text: "Tap what you spot · closer is easier", systemImage: "hand.tap.fill")
                        }
                        if seeking, seconds > 0 {
                            // This hunt's coins on the left, the hint on the right.
                            HStack(alignment: .bottom) {
                                CoinPill(amount: squad.coinsThisRound, halved: squad.hintUsed)
                                Spacer(minLength: 0)
                                if squad.state.settings.hints, !squad.hintUsed {
                                    HintKey { showNotice(hintNotice) }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Hunt.gutter)
            if showFound {
                Slam(text: "Found", colour: Hunt.text, size: 88, trigger: slams, burst: Hunt.player(squad.me.colour))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if menuOpen {
                DropCard(isPresented: $menuOpen, alignment: .topLeading, width: 300) {
                    SquadHuntMenu(squad: squad, isPresented: $menuOpen)
                }
                .padding(.top, Hunt.gutter + 64)
                .padding(.leading, Hunt.gutter)
            }
            if !introOver {
                SquadHuntIntro(squad: squad)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: menuOpen)
        .task(id: squad.huntStartsAt) {
            // Everyone's intro ends at the same moment: when the host's clock says so.
            guard let start = squad.huntStartsAt, start.timeIntervalSinceNow > 0 else {
                introOver = true
                return
            }
            introOver = false
            // A tick on each of 3, 2, 1, in time with the numbers.
            for mark in [3.0, 2.0, 1.0] {
                let wait = start.timeIntervalSinceNow - mark
                guard wait > -0.5 else { continue }
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                Sound.shared.play(.tick)
            }
            try? await Task.sleep(for: .seconds(max(0, start.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            Sound.shared.play(.go)
            withAnimation(.easeOut(duration: 0.35)) { introOver = true }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: feed)
        .onChange(of: squad.claimsMade) { old, new in
            guard new > old else { return }
            slams += 1
            let shown = slams
            showFound = true
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                if slams == shown { withAnimation(.easeOut(duration: 0.2)) { showFound = false } }
            }
        }
        .sensoryFeedback(.warning, trigger: squad.missLockedUntil) { _, now in now != nil }
        .onChange(of: squad.lastEvent) { _, event in show(event) }
        .onAppear {
            show(squad.lastEvent)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-debugHuntMenu") { menuOpen = true }
            if ProcessInfo.processInfo.arguments.contains("-debugHintNotice") { showNotice(hintNotice) }
            #endif
        }
    }

    /// It asks before it costs anything.
    private var hintNotice: Notice {
        Notice(title: "Use the hint?",
               message: "An arrow points to the nearest one. For the rest of this hunt, each one you find earns half the coins.",
               systemImage: "lightbulb.fill", tint: Hunt.sun,
               primary: .init(title: "Keep looking"),
               secondary: .init(title: "Use hint", systemImage: "lightbulb.fill") { [squad] in squad.useHint() })
    }

    private var huntStatus: some View {
        HStack(spacing: 10) {
            IconButton(systemImage: "line.3.horizontal", label: "Menu") { menuOpen = true }
            Countdown(until: squad.deadline) { ClockPill(seconds: $0) }
            HUDPill(systemImage: "lizard.fill", text: "\(left) left", tint: Hunt.limeLip)
        }
    }

    private func show(_ event: String?) {
        guard let event else { return }
        feed = event
        feedBy = squad.lastEventBy
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if feed == event { feed = nil }
        }
    }
}

/// The live scores over the camera: the top four, and you, wherever you are.
private struct MiniBoard: View {
    @ObservedObject var squad: SquadGame

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.player.id) { score in
                HStack(spacing: 8) {
                    Avatar(name: score.player.name, colour: score.player.colour, size: 28)
                    Text(score.player.id == squad.me.id ? "You" : score.player.name)
                        .font(.hunt(17, relativeTo: .subheadline)).foregroundStyle(Hunt.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    if squad.state.away.contains(score.player.id) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 13, weight: .black))
                            .foregroundStyle(Hunt.inkMuted)
                            .accessibilityLabel("Reconnecting")
                    }
                    Text("\(score.points)").font(.hunt(20, relativeTo: .headline)).foregroundStyle(Hunt.ink).monospacedDigit()
                        .contentTransition(.numericText())
                }
                .opacity(squad.state.away.contains(score.player.id) ? 0.5 : 1)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minWidth: 160, maxWidth: 230)
        .huntPlate(padding: 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: squad.state.chameleons)
    }

    private var rows: [SquadRules.Score] {
        let all = SquadRules.scores(squad.state)
        var top = Array(all.prefix(4))
        if !top.contains(where: { $0.player.id == squad.me.id }), let mine = all.first(where: { $0.player.id == squad.me.id }) {
            top[top.count - 1] = mine
        }
        return top
    }
}

// MARK: - Results

/// The podium, then the whole board. The camera stays live so everyone can walk over to
/// the ones nobody found.
private struct SquadResultsView: View {
    @ObservedObject var squad: SquadGame
    let ar: ARSessionController
    /// Rows come in from last place up, so first place lands last.
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scores: [SquadRules.Score] { SquadRules.scores(squad.state) }
    private var winners: [SquadRules.Score] { scores.filter { $0.points == scores.first?.points } }
    private var iWon: Bool { winners.count == 1 && winners.first?.player.id == squad.me.id }
    /// Three blocks can't show a tie that runs past third place (a four-way draw left
    /// someone off); the board alone tells it straight then.
    private var podiumIsFair: Bool { scores.count <= 3 || scores[3].points != scores[2].points }

    private var headline: String {
        guard winners.count == 1, let winner = winners.first else { return "Draw" }
        return winner.player.id == squad.me.id ? "You win" : "\(winner.player.name) wins"
    }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            // A phone on its side: the board on the left, scrolling if it must; the result
            // and the keys on the right. (In one column the keys ended up off the screen.)
            let sideways = !portrait && proxy.size.height < 500
            ZStack {
                if iWon { Confetti() }
                if sideways {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                LeaveButton(squad: squad)
                                Spacer()
                                // No height for it on the right: the coins go up here.
                                CoinsEarned(amount: squad.coinsThisRound, compact: true)
                                Spacer()
                                shareButton
                            }
                            ScrollView { board }
                                .scrollBounceBehavior(.basedOnSize)
                                .scrollIndicators(.hidden)
                        }
                        // Wide enough for the names, which otherwise shrank to "…".
                        .frame(width: min(440, proxy.size.width * 0.52))
                        VStack(spacing: 14) {
                            Slam(text: headline, colour: Hunt.text, size: 52, burst: Hunt.sun)
                            Spacer(minLength: 0)
                            actions(showCoins: false)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(Hunt.gutter)
                } else {
                    VStack(spacing: 14) {
                        HStack(alignment: .top) {
                            LeaveButton(squad: squad)
                            Spacer()
                            shareButton
                        }
                        Slam(text: headline, colour: Hunt.text, size: 60, burst: Hunt.sun)
                        // A phone has room for the podium or the board; the board wins. (Chosen
                        // from the size, not with ViewThatFits: see RowOrColumnLayout.)
                        if min(proxy.size.width, proxy.size.height) >= 600 && podiumIsFair {
                            let layout = portrait ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 28))
                            layout {
                                Podium(scores: Array(scores.prefix(3)), ranks: scores.indices.prefix(3).map { rank(of: $0) }, me: squad.me.id)
                                board.frame(maxWidth: 520)
                            }
                        } else {
                            board.frame(maxWidth: 520)
                        }
                        Spacer(minLength: 0)
                        actions(showCoins: true)
                    }
                    .padding(Hunt.gutter)
                }
            }
        }
        .sensoryFeedback(iWon ? .success : .warning, trigger: squad.state.phase)
        .onAppear {
            revealed = true
            // A fanfare for anyone on top, draws included.
            Sound.shared.play(winners.contains { $0.player.id == squad.me.id } ? .win : .lose)
        }
        .asksForReview(after: iWon)
    }

    /// The room with everyone's chameleons in their scorer's colour, to send.
    private var shareButton: some View {
        IconButton(systemImage: "square.and.arrow.up", label: "Share") {
            let title = headline
            let message = ShareCard.message("We just played ChameleonHunt: \(headline).")
            ar.snapshot { image in
                ShareCard.present(image: ShareCard.make(snapshot: image, headline: title,
                                                        detail: "ChameleonHunt · squad hide and seek"),
                                  message: message)
            }
        }
    }

    @ViewBuilder private func actions(showCoins: Bool) -> some View {
        if showCoins { CoinsEarned(amount: squad.coinsThisRound, detail: coinsDetail) }
        // Out in the room, every chameleon is now the colour of whoever got its point:
        // the finder's, or if nobody found it, the hider's.
        HUDPill(systemImage: "paintpalette.fill", text: "Colours show who scored")
        if squad.isHost {
            // Laid out like the one-device results: the way out on the left.
            ActionBar {
                Button(action: squad.backToLobby) { Label("Lobby", systemImage: "person.3.fill") }
                    .buttonStyle(HuntButtonStyle(kind: .secondary, large: true))
            } primary: {
                Button(action: squad.playAgain) { Label("Play again", systemImage: "arrow.clockwise").frame(minWidth: 220) }
                    .buttonStyle(.huntBig)
            } trailing: {
                EmptyView()
            }
        } else {
            HUDPill(systemImage: "hourglass", text: "Waiting for \(squad.hostName)")
        }
    }

    /// What the coins were for, when it was more than one thing.
    private var coinsDetail: String? {
        var parts: [String] = []
        if squad.coinsFromFinds > 0 { parts.append("\(squad.coinsFromFinds) finds") }
        if squad.coinsForUnfound > 0 { parts.append("\(squad.coinsForUnfound) never found") }
        if squad.coinsForWinning > 0 { parts.append("\(squad.coinsForWinning) top") }
        return parts.count > 1 ? parts.joined(separator: " · ") : nil
    }

    private var board: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                Image(systemName: "magnifyingglass").frame(width: 38).accessibilityLabel("Finds")
                Image(systemName: "eye.slash.fill").frame(width: 38).accessibilityLabel("Unfound")
                Text("PTS").frame(width: 46)
            }
            .font(.hunt(15, relativeTo: .caption))
            .foregroundStyle(Hunt.inkMuted)
            .padding(.horizontal, 10)
            ForEach(Array(scores.enumerated()), id: \.element.player.id) { index, score in
                HStack(spacing: 8) {
                    Text("\(rank(of: index))")
                        .font(.hunt(22, relativeTo: .headline)).foregroundStyle(Hunt.ink)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(rank(of: index) == 1 ? Hunt.sun : Hunt.paperLip))
                        .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 2))
                    Avatar(name: score.player.name, colour: score.player.colour, size: 34)
                    // The name gives way last: it shrinks before it's cut to "…".
                    Text(score.player.id == squad.me.id ? "You" : score.player.name)
                        .font(.hunt(20, relativeTo: .headline)).lineLimit(1).minimumScaleFactor(0.6)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Text("\(score.finds)").frame(width: 38)
                    Text("\(score.survivors)").frame(width: 38)
                    Text("\(score.points)").font(.hunt(26, relativeTo: .title3)).frame(width: 46)
                }
                .font(.hunt(20, relativeTo: .headline).monospacedDigit())
                .foregroundStyle(Hunt.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 50)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(score.player.id == squad.me.id ? Hunt.player(score.player.colour).opacity(0.45) : .clear))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(rank(of: index)). \(score.player.name), \(score.finds) found, \(score.survivors) unfound, \(score.points) points")
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed || reduceMotion ? 0 : 14)
                .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(Double(scores.count - 1 - index) * 0.15),
                           value: revealed)
            }
        }
        .huntPlate(padding: 12)
    }

    /// Joint places share a rank.
    private func rank(of index: Int) -> Int {
        let points = scores[index].points
        return (scores.firstIndex { $0.points == points } ?? index) + 1
    }
}

/// The top three on their blocks: first in the middle, highest, with the crown.
private struct Podium: View {
    let scores: [SquadRules.Score]
    /// Joint places share a rank, and a block height.
    let ranks: [Int]
    let me: UUID
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Second, first, third, left to right.
        let order = [1, 0, 2].filter { $0 < scores.count }
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(order, id: \.self) { place in
                let score = scores[place]
                let rank = min(max(ranks[place], 1), 3) - 1
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        MascotImage(pose: rank == 0 ? .standing : .curled, view: .hero, resolution: 360,
                                    tint: Hunt.playerTint(score.player.colour))
                            .frame(width: 104, height: 104)
                        if rank == 0 {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 30, weight: .black))
                                .foregroundStyle(Hunt.sun)
                                .shadow(color: Hunt.ink, radius: 0, x: 0, y: 3)
                                .offset(x: 8, y: -22)
                        }
                    }
                    Text(score.player.id == me ? "You" : score.player.name)
                        .font(.hunt(17, relativeTo: .headline)).foregroundStyle(Hunt.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .sticker(Hunt.player(score.player.colour), radius: 10, shadow: 3)
                        .frame(maxWidth: 116)
                        .padding(.bottom, 6)
                    VStack(spacing: 0) {
                        Text(["1st", "2nd", "3rd"][rank]).font(.hunt(26, relativeTo: .title3))
                        Text("\(score.points) pts").font(.chat(.caption, weight: .heavy))
                    }
                    .foregroundStyle(Hunt.ink)
                    .frame(width: 116, height: risen || reduceMotion ? [150, 110, 80][rank] : 20, alignment: .top)
                    .padding(.top, 8)
                    .sticker([Hunt.sun, Hunt.paper, Hunt.orange][rank], radius: 14, shadow: 5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(["First", "Second", "Third"][rank]): \(score.player.name), \(score.points) points")
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.2)) { risen = true }
        }
    }
}
